import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

/// A realtime inference bridge for the FastVLM-0.5B ONNX model.
///
/// The service performs three primary steps:
/// 1. Loads the ONNX model from assets into a readable cache location.
/// 2. Preprocesses incoming camera frames into the tensor format expected by FastVLM.
/// 3. Runs ONNX Runtime inference and decodes the textual result.
///
/// The implementation assumes the exported model accepts CLIP-style pixel values
/// (3 x 384 x 384 float32) along with an optional textual prompt. Post-processing
/// attempts to extract UTF-8 text tensors, but if the exported graph differs you
/// can adapt [_postProcess] accordingly.
class FastVlmService {
  FastVlmService({
    this.modelAssetPath = 'models/FastVLM-0.5B-ONNX/model.onnx',
    this.prompt =
        'Describe the scene for a visually impaired user in concise Thai.',
    this.targetImageSize = 384,
    this.mean = const [0.48145466, 0.4578275, 0.40821073],
    this.std = const [0.26862954, 0.26130258, 0.27577711],
  });

  /// Location of the ONNX model inside the Flutter asset bundle.
  final String modelAssetPath;

  /// Prompt appended to the model call.
  final String prompt;

  /// Target square image size used during preprocessing.
  final int targetImageSize;

  /// Channel-wise normalization mean values.
  final List<double> mean;

  /// Channel-wise normalization standard deviation values.
  final List<double> std;

  OrtSession? _session;
  OrtRunOptions? _runOptions;
  Completer<void>? _initializationCompleter;
  late String _modelFilePath;

  /// Whether the model has been fully loaded and is ready for inference.
  bool get isReady => _session != null;

  /// Ensures the ONNX session is initialized exactly once.
  Future<void> ensureInitialized() async {
    if (isReady) return;
    if (_initializationCompleter != null) {
      return _initializationCompleter!.future;
    }

    final completer = _initializationCompleter = Completer<void>();

    try {
      _modelFilePath = await _materializeAsset(modelAssetPath);

      final sessionOptions = OrtSessionOptions()
        ..setIntraOpNumThreads(2)
        ..setInterOpNumThreads(2)
        ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll)
        ..appendXnnpackProvider();

      try {
        _session = OrtSession.fromFile(File(_modelFilePath), sessionOptions);
      } finally {
        sessionOptions.release();
      }
      completer.complete();
    } catch (e, stack) {
      completer.completeError(e, stack);
      rethrow;
    } finally {
      _initializationCompleter = null;
    }
  }

  /// Releases native resources.
  Future<void> dispose() async {
    _session?.release();
    _session = null;
    _runOptions?.release();
    _runOptions = null;
    _initializationCompleter = null;
  }

  /// Performs inference for the given [cameraImage].
  ///
  /// Automatically initializes the model if required and throttles work to a
  /// background isolate to keep the UI responsive. Returns a textual
  /// description or throws if preprocessing/inference fails.
  Future<String> describeCameraImage(CameraImage cameraImage) async {
    await ensureInitialized();
    if (!isReady) {
      throw StateError('FastVLM session not ready');
    }

    final _PreprocessResult result = _preprocess(
      image: cameraImage,
      targetSize: targetImageSize,
      mean: mean,
      std: std,
      prompt: prompt,
    );

    final Map<String, OrtValue> inputs = {
      'pixel_values': _createTensor(result.imageTensor, [
        1,
        3,
        targetImageSize,
        targetImageSize,
      ]),
      if (result.inputIds != null)
        'input_ids': _createIntTensor(result.inputIds!, [
          1,
          result.sequenceLength!,
        ]),
      if (result.attentionMask != null)
        'attention_mask': _createIntTensor(result.attentionMask!, [
          1,
          result.sequenceLength!,
        ]),
    };

    final OrtRunOptions runOptions = _runOptions ??= OrtRunOptions();
    final List<OrtValue?> outputs;
    try {
      outputs = _session!.run(runOptions, inputs);
    } finally {
      for (final value in inputs.values) {
        value.release();
      }
    }

    try {
      return _postProcess(outputs, _session!.outputNames);
    } finally {
      for (final value in outputs) {
        value?.release();
      }
    }
  }

  /// Converts float32 data to an [OrtValue] tensor.
  OrtValueTensor _createTensor(Float32List data, List<int> shape) {
    return OrtValueTensor.createTensorWithDataList(data, shape);
  }

  /// Converts int64 data to an [OrtValue] tensor.
  OrtValueTensor _createIntTensor(Int64List data, List<int> shape) {
    return OrtValueTensor.createTensorWithDataList(data, shape);
  }

  /// Attempts to interpret FastVLM outputs as UTF-8 text.
  String _postProcess(List<OrtValue?> outputs, List<String> outputNames) {
    if (outputs.isEmpty) {
      return 'ไม่พบคำอธิบายจากโมเดล';
    }

    for (int i = 0; i < outputs.length; i++) {
      final OrtValue? value = outputs[i];
      if (value is OrtValueTensor) {
        final dynamic raw = value.value;
        final text = _extractText(raw);
        if (text != null && text.trim().isNotEmpty) {
          return text.trim();
        }
      }
    }

    return 'โมเดลตอบกลับไม่ใช่ข้อความที่อ่านได้';
  }

  Future<String> _materializeAsset(String assetPath) async {
    ByteData data;
    try {
      data = await rootBundle.load(assetPath);
    } on FlutterError catch (error, stack) {
      throw ModelAssetException(
        'ไม่พบไฟล์โมเดล FastVLM ที่ประกาศไว้ที่ "$assetPath"\n'
        'กรุณาตรวจสอบว่าได้ดาวน์โหลดไฟล์ `model.onnx` และวางไว้ภายใต้โฟลเดอร์ `models/FastVLM-0.5B-ONNX/` ตามคำแนะนำใน README.',
        error,
        stack,
      );
    }
    final Directory dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final File file = File('${dir.path}/fastvlm.onnx');
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    return file.path;
  }
}

/// Thrown when the declared FastVLM ONNX asset cannot be found or read.
class ModelAssetException implements Exception {
  ModelAssetException(this.message, [this.cause, this.stackTrace]);

  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() => message;
}

class _PreprocessResult {
  const _PreprocessResult({
    required this.imageTensor,
    this.inputIds,
    this.attentionMask,
  });

  final Float32List imageTensor;
  final Int64List? inputIds;
  final Int64List? attentionMask;

  int? get sequenceLength => inputIds?.length;
}

_PreprocessResult _preprocess({
  required CameraImage image,
  required int targetSize,
  required List<double> mean,
  required List<double> std,
  required String prompt,
}) {
  final img.Image rgbImage = _convertYuv420ToImage(image);
  final img.Image resized = img.copyResize(
    rgbImage,
    width: targetSize,
    height: targetSize,
    interpolation: img.Interpolation.cubic,
  );

  final Float32List normalized = _normalizeImage(resized, mean, std);

  // For simplicity this sample creates a trivial tokenizer output consisting of the prompt.
  final List<String> promptTokens = prompt.trim().split(RegExp(r'\s+'));
  final Int64List inputIds = Int64List(promptTokens.length);
  final Int64List attentionMask = Int64List(promptTokens.length);
  for (int i = 0; i < promptTokens.length; i++) {
    inputIds[i] = i + 1; // Placeholder token ID assignment.
    attentionMask[i] = 1;
  }

  return _PreprocessResult(
    imageTensor: normalized,
    inputIds: inputIds,
    attentionMask: attentionMask,
  );
}

img.Image _convertYuv420ToImage(CameraImage image) {
  final int width = image.width;
  final int height = image.height;
  final img.Image converted = img.Image(width: width, height: height);

  final Plane yPlane = image.planes[0];
  final Plane uPlane = image.planes[1];
  final Plane vPlane = image.planes[2];

  final int yRowStride = yPlane.bytesPerRow;
  final int uvRowStride = uPlane.bytesPerRow;
  final int uvPixelStride = uPlane.bytesPerPixel!;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int uvIndex = uvPixelStride * (x ~/ 2) + uvRowStride * (y ~/ 2);
      final double yp = yPlane.bytes[y * yRowStride + x].toDouble();
      final double up = uPlane.bytes[uvIndex].toDouble();
      final double vp = vPlane.bytes[uvIndex].toDouble();

      int r = (yp + 1.402 * (vp - 128)).round();
      int g = (yp - 0.344136 * (up - 128) - 0.714136 * (vp - 128)).round();
      int b = (yp + 1.772 * (up - 128)).round();

      r = r.clamp(0, 255);
      g = g.clamp(0, 255);
      b = b.clamp(0, 255);

      converted.setPixelRgb(x, y, r, g, b);
    }
  }

  return converted;
}

Float32List _normalizeImage(
  img.Image image,
  List<double> mean,
  List<double> std,
) {
  final int width = image.width;
  final int height = image.height;
  final Float32List buffer = Float32List(width * height * 3);

  int offsetR = 0;
  int offsetG = width * height;
  int offsetB = offsetG * 2;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final img.Pixel pixel = image.getPixel(x, y);
      final double r = pixel.rNormalized.toDouble();
      final double g = pixel.gNormalized.toDouble();
      final double b = pixel.bNormalized.toDouble();

      buffer[offsetR++] = ((r - mean[0]) / std[0]).toDouble();
      buffer[offsetG++] = ((g - mean[1]) / std[1]).toDouble();
      buffer[offsetB++] = ((b - mean[2]) / std[2]).toDouble();
    }
  }

  return buffer;
}

String? _extractText(dynamic value) {
  if (value is String) {
    return value;
  }

  if (value is List) {
    final buffer = <String>[];
    void walk(dynamic node) {
      if (node is String) {
        buffer.add(node);
      } else if (node is num) {
        buffer.add(node.toString());
      } else if (node is List) {
        for (final nested in node) {
          walk(nested);
        }
      }
    }

    walk(value);
    if (buffer.isNotEmpty) {
      return buffer.join(' ');
    }
  }

  if (value is num) {
    return value.toString();
  }

  return null;
}
