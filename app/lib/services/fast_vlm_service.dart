import 'dart:async';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:camera/camera.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter/foundation.dart';
import 'model_loader.dart';

/// Provides an interface for running FastVLM model inference in Flutter.
///
/// Responsibilities:
/// 1. Initialize and manage ONNX model sessions (vision, embedding, decoder).
/// 2. Preprocess camera frames into normalized tensors.
/// 3. Run inference and combine model embeddings.
/// 4. Clean up resources safely after use.
class FastVlmService {
  OrtSession? _visionSession;
  OrtSession? _embedSession;
  OrtSession? _decoderSession;
  Completer<void>? _initCompleter;

  static const int _targetImageSize = 384;
  static const int _numDecoderLayers = 18;
  static const int _numAttentionHeads = 8;
  static const int _headDim = 96;

  static const List<double> _imageMean = [0.48145466, 0.4578275, 0.40821073];
  static const List<double> _imageStd = [0.26862954, 0.26130258, 0.27577711];

  bool get isReady =>
      _visionSession != null &&
      _embedSession != null &&
      _decoderSession != null;

  /// Ensures that the FastVLM model sessions are initialized.
  /// This method downloads models if missing and creates ONNX sessions.
  Future<void> ensureInitialized() async {
    if (isReady) return;
    if (_initCompleter != null) return _initCompleter!.future;

    final completer = _initCompleter = Completer<void>();
    try {
      debugPrint('Initializing FastVLM models.');
      await ModelLoader.ensureModelsDownloaded();
      final paths = await ModelLoader.getAllModelPaths();

      final ort = OnnxRuntime();
      _visionSession = await ort.createSession(paths['vision_encoder.onnx']!);
      _embedSession = await ort.createSession(paths['embed_tokens.onnx']!);
      _decoderSession = await ort.createSession(
        paths['decoder_model_merged.onnx']!,
      );

      debugPrint('FastVLM models loaded successfully.');
      completer.complete();
    } catch (e, st) {
      debugPrint('FastVLM initialization failed: $e');
      debugPrint('Stack trace: $st');
      completer.completeError(e, st);
      rethrow;
    } finally {
      _initCompleter = null;
    }
  }

  /// Runs inference on a camera frame and produces a descriptive output.
  Future<String> describeCameraImage(
    CameraImage frame, {
    String prompt = 'Describe this image for a visually impaired person:',
  }) async {
    await ensureInitialized();
    if (!isReady) throw StateError('FastVLM service not initialized.');

    final preprocessed = _preprocessImage(frame, prompt);

    final tensors = <OrtValue>[];
    Map<String, OrtValue>? visionOutputs;
    Map<String, OrtValue>? embedOutputs;
    Map<String, OrtValue>? decoderOutputs;

    try {
      // Vision encoder
      final pixelTensor = await OrtValue.fromList(preprocessed.imageTensor, [
        1,
        3,
        _targetImageSize,
        _targetImageSize,
      ]);
      tensors.add(pixelTensor);

      visionOutputs = await _visionSession!.run({'pixel_values': pixelTensor});
      final visionEmbeddings = visionOutputs.values.first;

      // Text embedding
      final idsTensor = await OrtValue.fromList(preprocessed.inputIds, [
        1,
        preprocessed.inputIds.length,
      ]);
      tensors.add(idsTensor);

      embedOutputs = await _embedSession!.run({'input_ids': idsTensor});
      final textEmbeddings = embedOutputs.values.first;

      // Combine embeddings
      final combined = await _combineEmbeddings(
        visionEmbeddings,
        textEmbeddings,
      );
      debugPrint(
        'Combined embeddings: seq_len=${combined.seqLength}, hidden_size=${combined.hiddenSize}',
      );

      // Prepare decoder inputs
      final decoderInputs = await _prepareDecoderInputs(combined);
      tensors.addAll(decoderInputs.values);

      // Decoder forward pass
      decoderOutputs = await _decoderSession!.run(decoderInputs);
      final logits = decoderOutputs['logits'];
      if (logits == null) throw StateError('Decoder did not return logits.');

      debugPrint('Decoder output shape: ${logits.shape}');
      return _decodeOutput(logits, prompt);
    } catch (e, st) {
      debugPrint('Inference error: $e');
      debugPrint('Stack trace: $st');
      rethrow;
    } finally {
      await _cleanupTensors(tensors);
      await _cleanupOutputs(visionOutputs);
      await _cleanupOutputs(embedOutputs);
      await _cleanupOutputs(decoderOutputs);
    }
  }

  /// Combines vision and text embeddings into a single tensor.
  Future<_CombinedEmbeddings> _combineEmbeddings(
    OrtValue visionOutput,
    OrtValue textOutput,
  ) async {
    final visionShape = visionOutput.shape!;
    final textShape = textOutput.shape!;
    final visionSeqLen = visionShape[1];
    final textSeqLen = textShape[1];
    final hiddenSize = visionShape[2];

    debugPrint('Vision output shape: $visionShape');
    debugPrint('Text output shape: $textShape');

    final visionList = await visionOutput.asFlattenedList();
    final textList = await textOutput.asFlattenedList();

    final visionData = Float32List.fromList(
      visionList.map((e) => (e as num).toDouble()).toList(),
    );
    final textData = Float32List.fromList(
      textList.map((e) => (e as num).toDouble()).toList(),
    );

    final combined = Float32List(visionData.length + textData.length);
    combined.setRange(0, visionData.length, visionData);
    combined.setRange(visionData.length, combined.length, textData);

    debugPrint('Combined ${combined.length} embedding values (FP32).');

    return _CombinedEmbeddings(
      data: combined,
      seqLength: visionSeqLen + textSeqLen,
      hiddenSize: hiddenSize,
    );
  }

  /// Preprocesses a camera frame and tokenizes the prompt.
  _PreprocessResult _preprocessImage(CameraImage frame, String prompt) {
    final rgbImage = _yuv420ToRgb(frame);
    final resized = img.copyResize(
      rgbImage,
      width: _targetImageSize,
      height: _targetImageSize,
    );
    final normalized = _normalizeImage(resized);
    final inputIds = _tokenizePrompt(prompt);

    return _PreprocessResult(imageTensor: normalized, inputIds: inputIds);
  }

  /// Prepares decoder input tensors using the combined embeddings.
  Future<Map<String, OrtValue>> _prepareDecoderInputs(
    _CombinedEmbeddings combined,
  ) async {
    final totalSeqLen = combined.seqLength;
    final inputs = <String, OrtValue>{};

    // Main embeddings
    inputs['inputs_embeds'] = await OrtValue.fromList(combined.data, [
      1,
      totalSeqLen,
      combined.hiddenSize,
    ]);

    // Attention mask
    final attentionMask = Int64List(totalSeqLen)..fillRange(0, totalSeqLen, 1);
    inputs['attention_mask'] = await OrtValue.fromList(attentionMask, [
      1,
      totalSeqLen,
    ]);

    // Position IDs
    final positionIds = Int64List(totalSeqLen);
    for (int i = 0; i < totalSeqLen; i++) positionIds[i] = i;
    inputs['position_ids'] = await OrtValue.fromList(positionIds, [
      1,
      totalSeqLen,
    ]);

    // Initialize empty key/value tensors
    final kvShape = [1, _numAttentionHeads, 1, _headDim];
    final dummyKV = Float32List(_numAttentionHeads * _headDim);

    for (int i = 0; i < _numDecoderLayers; i++) {
      inputs['past_key_values.$i.key'] = await OrtValue.fromList(
        dummyKV,
        kvShape,
      );
      inputs['past_key_values.$i.value'] = await OrtValue.fromList(
        dummyKV,
        kvShape,
      );
    }

    return inputs;
  }

  /// Produces a simple text summary from the model output tensor.
  String _decodeOutput(OrtValue logitsValue, String prompt) {
    final shape = logitsValue.shape;
    return 'Scene analysis complete.\n'
        'Model processed image successfully.\n'
        'Output shape: ${shape?.join(" x ")}\n'
        'Prompt: "$prompt"\n\n'
        'Text decoding requires tokenizer integration.';
  }

  /// Converts a YUV420 camera image to RGB format.
  img.Image _yuv420ToRgb(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final output = img.Image(width: width, height: height);

    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final yRowStride = yPlane.bytesPerRow;
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel!;

    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        final uvRow = row ~/ 2;
        final uvCol = col ~/ 2;
        final uvIndex = uvPixelStride * uvCol + uvRowStride * uvRow;

        final y = yPlane.bytes[row * yRowStride + col].toDouble();
        final u = uPlane.bytes[uvIndex].toDouble();
        final v = vPlane.bytes[uvIndex].toDouble();

        final r = (y + 1.402 * (v - 128)).round().clamp(0, 255);
        final g = (y - 0.344136 * (u - 128) - 0.714136 * (v - 128))
            .round()
            .clamp(0, 255);
        final b = (y + 1.772 * (u - 128)).round().clamp(0, 255);

        output.setPixelRgb(col, row, r, g, b);
      }
    }

    return output;
  }

  /// Normalizes an RGB image into a Float32 tensor.
  Float32List _normalizeImage(img.Image image) {
    final width = image.width;
    final height = image.height;
    final output = Float32List(3 * height * width);
    int index = 0;

    for (final pixel in image) {
      output[index++] = (pixel.rNormalized - _imageMean[0]) / _imageStd[0];
      output[index++] = (pixel.gNormalized - _imageMean[1]) / _imageStd[1];
      output[index++] = (pixel.bNormalized - _imageMean[2]) / _imageStd[2];
    }
    return output;
  }

  /// Simple tokenizer placeholder for prompts.
  /// Replace with a real tokenizer for production use.
  Int64List _tokenizePrompt(String prompt) {
    final tokens = prompt.trim().split(RegExp(r'\s+'));
    final ids = Int64List(tokens.length);
    for (int i = 0; i < tokens.length; i++) {
      ids[i] = 100 + i;
    }
    return ids;
  }

  /// Frees temporary OrtValue tensors.
  Future<void> _cleanupTensors(List<OrtValue> tensors) async {
    for (final t in tensors) {
      try {
        await t.dispose();
      } catch (_) {}
    }
  }

  /// Frees ONNX output maps.
  Future<void> _cleanupOutputs(Map<String, OrtValue>? outputs) async {
    if (outputs == null) return;
    for (final v in outputs.values) {
      try {
        await v.dispose();
      } catch (_) {}
    }
  }

  /// Closes ONNX sessions and releases resources.
  Future<void> dispose() async {
    debugPrint('Disposing FastVLM service.');
    try {
      await _visionSession?.close();
      await _embedSession?.close();
      await _decoderSession?.close();
    } catch (_) {}
    _visionSession = null;
    _embedSession = null;
    _decoderSession = null;
    debugPrint('FastVLM service disposed.');
  }
}

/// Represents combined embeddings used by the decoder.
class _CombinedEmbeddings {
  final Float32List data;
  final int seqLength;
  final int hiddenSize;

  _CombinedEmbeddings({
    required this.data,
    required this.seqLength,
    required this.hiddenSize,
  });
}

/// Internal structure for image preprocessing output.
class _PreprocessResult {
  final Float32List imageTensor;
  final Int64List inputIds;

  _PreprocessResult({required this.imageTensor, required this.inputIds});
}
