import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'model_loader.dart';

class FastVlmService {
  OrtSession? _visionSession;
  OrtSession? _embedSession;
  OrtSession? _decoderSession;
  Completer<void>? _initCompleter;

  bool get isReady =>
      _visionSession != null &&
      _embedSession != null &&
      _decoderSession != null;

  Future<void> ensureInitialized() async {
    if (isReady) return;
    if (_initCompleter != null) return _initCompleter!.future;

    final c = _initCompleter = Completer<void>();
    try {
      await ModelLoader.ensureModelsDownloaded();
      final paths = await ModelLoader.getAllModelPaths();

      final ort = OnnxRuntime();

      _visionSession = await ort.createSession(
        paths['vision_encoder_fp16.onnx']!,
      );
      _embedSession = await ort.createSession(paths['embed_tokens_fp16.onnx']!);
      _decoderSession = await ort.createSession(
        paths['decoder_model_merged_fp16.onnx']!,
      );

      c.complete();
    } catch (e, st) {
      c.completeError(e, st);
      rethrow;
    } finally {
      _initCompleter = null;
    }
  }

  Future<String> describeCameraImage(
    CameraImage frame, {
    String prompt = "Describe scene in Thai",
  }) async {
    await ensureInitialized();
    if (!isReady) throw StateError("FastVLM not ready");

    final _PreprocessResult proc = _preprocess(
      image: frame,
      targetSize: 384,
      mean: const [0.48145466, 0.4578275, 0.40821073],
      std: const [0.26862954, 0.26130258, 0.27577711],
      prompt: prompt,
    );

    final visionOut = await _visionSession!.run({
      "pixel_values": await _toOrtFloatValue(proc.imageTensor, [
        1,
        3,
        384,
        384,
      ]),
    });

    final embedOut = await _embedSession!.run({
      "input_ids": await _toOrtIntValue(proc.inputIds!, [
        1,
        proc.sequenceLength!,
      ]),
    });

    final decoderOut = await _decoderSession!.run({
      "encoder_hidden_states": visionOut.values.first,
      "input_embeddings": embedOut.values.first,
      "attention_mask": await _toOrtIntValue(proc.attentionMask!, [
        1,
        proc.sequenceLength!,
      ]),
    });

    final text = await _postProcess(
      decoderOut.values.toList(),
      _decoderSession!.outputNames,
    );

    // cleanup
    for (final v in visionOut.values) {
      await v.dispose();
    }
    for (final v in embedOut.values) {
      await v.dispose();
    }
    for (final v in decoderOut.values) {
      await v.dispose();
    }

    return text;
  }

  Future<void> dispose() async {
    await _visionSession?.close();
    await _embedSession?.close();
    await _decoderSession?.close();
    _visionSession = _embedSession = _decoderSession = null;
  }

  // ---- tensor helpers ----

  Future<OrtValue> _toOrtFloatValue(Float32List data, List<int> shape) {
    return OrtValue.fromList(data, shape);
  }

  Future<OrtValue> _toOrtIntValue(Int64List data, List<int> shape) {
    return OrtValue.fromList(data, shape);
  }

  // ---- output postprocess ----

  Future<String> _postProcess(
    List<OrtValue> outputs,
    List<String> outputNames,
  ) async {
    if (outputs.isEmpty) return 'ไม่พบคำอธิบายจากโมเดล';

    for (final v in outputs) {
      final raw = await v.asFlattenedList();
      final text = _extractText(raw);
      if (text != null && text.trim().isNotEmpty) {
        return text.trim();
      }
    }
    return 'โมเดลตอบกลับไม่ใช่ข้อความที่อ่านได้';
  }
}

/// --- Helper classes/functions ---
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

  // placeholder tokenizer
  final List<String> promptTokens = prompt.trim().split(RegExp(r'\s+'));
  final Int64List inputIds = Int64List(promptTokens.length);
  final Int64List attentionMask = Int64List(promptTokens.length);
  for (int i = 0; i < promptTokens.length; i++) {
    inputIds[i] = i + 1;
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
  int offsetB = width * height * 2;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final img.Pixel pixel = image.getPixel(x, y);
      final double r = pixel.rNormalized.toDouble();
      final double g = pixel.gNormalized.toDouble();
      final double b = pixel.bNormalized.toDouble();

      buffer[offsetR++] = (r - mean[0]) / std[0];
      buffer[offsetG++] = (g - mean[1]) / std[1];
      buffer[offsetB++] = (b - mean[2]) / std[2];
    }
  }

  return buffer;
}

String? _extractText(dynamic value) {
  if (value is String) return value;

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
    if (buffer.isNotEmpty) return buffer.join(' ');
  }

  if (value is num) return value.toString();

  return null;
}
