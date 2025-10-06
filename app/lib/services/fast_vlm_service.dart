import 'dart:async';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:camera/camera.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter/foundation.dart';

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

      debugPrint('✅ FastVLM models loaded successfully');
      c.complete();
    } catch (e, st) {
      debugPrint('❌ FastVLM initialization error: $e');
      c.completeError(e, st);
      rethrow;
    } finally {
      _initCompleter = null;
    }
  }

  Future<String> describeCameraImage(
    CameraImage frame, {
    String prompt = "Describe this image for a visually impaired person:",
  }) async {
    await ensureInitialized();
    if (!isReady) throw StateError('FastVLM not ready');

    // Preprocess frame
    final pre = _preprocess(
      image: frame,
      targetSize: 384,
      mean: const [0.48145466, 0.4578275, 0.40821073],
      std: const [0.26862954, 0.26130258, 0.27577711],
      prompt: prompt,
    );

    OrtValue? pixelTensor;
    OrtValue? idsTensor;
    OrtValue? inputsEmbedsTensor;
    OrtValue? attentionMaskTensor;
    OrtValue? positionIdsTensor;

    Map<String, OrtValue>? vOut;
    Map<String, OrtValue>? eOut;
    Map<String, OrtValue>? dOut;

    try {
      // 1) Vision encoder
      pixelTensor = await OrtValue.fromList(pre.imageTensor, [1, 3, 384, 384]);
      vOut = await _visionSession!.run({'pixel_values': pixelTensor});
      final visionOutput = vOut.values.first;

      // 2) Text embeddings
      idsTensor = await OrtValue.fromList(pre.inputIds!, [
        1,
        pre.inputIds!.length,
      ]);
      eOut = await _embedSession!.run({'input_ids': idsTensor});
      final textEmbeddings = eOut.values.first;

      // 3) Combine vision and text embeddings
      final combined = await _combineEmbeddings(visionOutput, textEmbeddings);
      final totalSeqLen = combined.seqLength;

      debugPrint(
        '📊 Combined seq_len: $totalSeqLen, hidden_size: ${combined.hiddenSize}',
      );

      // 4) Create inputs for decoder
      inputsEmbedsTensor = await OrtValue.fromList(combined.data, [
        1,
        totalSeqLen,
        combined.hiddenSize,
      ]);

      // Attention mask: all 1s
      final attentionMask = Int64List(totalSeqLen);
      for (int i = 0; i < totalSeqLen; i++) {
        attentionMask[i] = 1;
      }
      attentionMaskTensor = await OrtValue.fromList(attentionMask, [
        1,
        totalSeqLen,
      ]);

      // Position IDs: [0, 1, 2, ..., totalSeqLen-1]
      final positionIds = Int64List(totalSeqLen);
      for (int i = 0; i < totalSeqLen; i++) {
        positionIds[i] = i;
      }
      positionIdsTensor = await OrtValue.fromList(positionIds, [
        1,
        totalSeqLen,
      ]);

      // 5) Build decoder inputs with past_key_values
      final decoderInputs = <String, OrtValue>{
        'inputs_embeds': inputsEmbedsTensor,
        'attention_mask': attentionMaskTensor,
        'position_ids': positionIdsTensor,
      };

      // Initialize empty past_key_values for 18 decoder layers
      // Shape: [batch_size, num_heads, 0, head_dim] for initial run
      for (int i = 0; i < 18; i++) {
        final emptyKV = Float32List(0);
        decoderInputs['past_key_values.$i.key'] = await OrtValue.fromList(
          emptyKV,
          [1, 8, 0, 96], // num_heads=8, head_dim=96 for 0.5B model
        );
        decoderInputs['past_key_values.$i.value'] = await OrtValue.fromList(
          emptyKV,
          [1, 8, 0, 96],
        );
      }

      // 6) Run decoder
      dOut = await _decoderSession!.run(decoderInputs);

      // 7) Process output
      final logitsValue = dOut['logits'];
      if (logitsValue == null) {
        return 'No logits output from decoder';
      }

      debugPrint('✅ Decoder output shape: ${logitsValue.shape}');

      // For now, return success message with shapes
      // TODO: Implement proper token decoding
      return _decodeOutput(logitsValue, prompt);
    } catch (e, st) {
      debugPrint('❌ Inference error: $e\n$st');
      rethrow;
    } finally {
      // Cleanup
      await pixelTensor?.dispose();
      await idsTensor?.dispose();
      await inputsEmbedsTensor?.dispose();
      await attentionMaskTensor?.dispose();
      await positionIdsTensor?.dispose();

      Future<void> disposeMap(Map<String, OrtValue>? m) async {
        if (m == null) return;
        for (final v in m.values) {
          await v.dispose();
        }
      }

      await disposeMap(vOut);
      await disposeMap(eOut);
      await disposeMap(dOut);
    }
  }

  // Combine vision and text embeddings
  Future<_CombinedEmbeddings> _combineEmbeddings(
    OrtValue visionOutput,
    OrtValue textOutput,
  ) async {
    final visionShape = visionOutput.shape!;
    final textShape = textOutput.shape!;

    final visionSeqLen = visionShape[1];
    final textSeqLen = textShape[1];
    final hiddenSize = visionShape[2];

    final totalSeqLen = visionSeqLen + textSeqLen;

    // Extract data from OrtValue - try multiple methods
    final visionRaw = _extractFloat32Data(visionOutput);
    final textRaw = _extractFloat32Data(textOutput);

    debugPrint(
      '🔍 Vision data length: ${visionRaw.length}, expected: ${visionSeqLen * hiddenSize}',
    );
    debugPrint(
      '🔍 Text data length: ${textRaw.length}, expected: ${textSeqLen * hiddenSize}',
    );

    // Combine the flattened arrays
    final combined = Float32List(totalSeqLen * hiddenSize);

    // Copy vision embeddings
    combined.setRange(0, visionRaw.length, visionRaw);

    // Copy text embeddings after vision embeddings
    combined.setRange(visionRaw.length, combined.length, textRaw);

    debugPrint(
      '✅ Combined embeddings: vision=${visionRaw.length}, text=${textRaw.length}, total=${combined.length}',
    );

    return _CombinedEmbeddings(
      data: combined,
      seqLength: totalSeqLen,
      hiddenSize: hiddenSize,
    );
  }

  // Extract Float32List from OrtValue (handles different API versions)
  Float32List _extractFloat32Data(OrtValue ortValue) {
    try {
      // Method 1: Direct cast (some versions)
      final data = ortValue as Float32List;
      return data;
    } catch (_) {
      try {
        // Method 2: Check if it has a 'data' property
        final dynamic value = ortValue;
        if (value.data != null) {
          return value.data as Float32List;
        }
      } catch (_) {}

      try {
        // Method 3: Try toList and convert
        final dynamic value = ortValue;
        final list = value.toList();
        if (list is List<double>) {
          return Float32List.fromList(list);
        } else if (list is List) {
          // Flatten nested list
          final flattened = <double>[];
          _flattenList(list, flattened);
          return Float32List.fromList(flattened);
        }
      } catch (_) {}

      throw UnsupportedError(
        'Could not extract Float32List from OrtValue. '
        'Type: ${ortValue.runtimeType}. '
        'Please check flutter_onnxruntime documentation for your version.',
      );
    }
  }

  // Helper to flatten nested lists
  void _flattenList(List list, List<double> output) {
    for (final item in list) {
      if (item is List) {
        _flattenList(item, output);
      } else if (item is num) {
        output.add(item.toDouble());
      }
    }
  }

  // Decode output (placeholder for now)
  String _decodeOutput(OrtValue logitsValue, String prompt) {
    final shape = logitsValue.shape;

    // TODO: Implement proper tokenizer and decoding
    // For now, return a useful placeholder
    return 'Scene analysis:\n'
        '• Model processed image successfully\n'
        '• Output shape: ${shape?.join('x')}\n'
        '• Prompt: $prompt\n\n'
        'Note: Full text decoding coming soon...';
  }

  Future<void> dispose() async {
    await _visionSession?.close();
    await _embedSession?.close();
    await _decoderSession?.close();
    _visionSession = _embedSession = _decoderSession = null;
  }

  // ---------- Preprocess ----------
  _PreprocessResult _preprocess({
    required CameraImage image,
    required int targetSize,
    required List<double> mean,
    required List<double> std,
    required String prompt,
  }) {
    final rgb = _yuv420ToRgb(image);
    final resized = img.copyResize(
      rgb,
      width: targetSize,
      height: targetSize,
      interpolation: img.Interpolation.cubic,
    );
    final Float32List pixels = _normalize(resized, mean, std);

    // Simple tokenization (replace with real tokenizer later)
    final toks = prompt.trim().split(RegExp(r'\s+'));
    final ids = Int64List(toks.length);
    for (int i = 0; i < toks.length; i++) {
      ids[i] = 100 + i; // Placeholder token IDs
    }

    return _PreprocessResult(imageTensor: pixels, inputIds: ids);
  }

  img.Image _yuv420ToRgb(CameraImage image) {
    final w = image.width, h = image.height;
    final out = img.Image(width: w, height: h);

    final y = image.planes[0];
    final u = image.planes[1];
    final v = image.planes[2];

    final yRow = y.bytesPerRow;
    final uvRow = u.bytesPerRow;
    final uvPix = u.bytesPerPixel!;

    for (int row = 0; row < h; row++) {
      for (int col = 0; col < w; col++) {
        final uvIndex = uvPix * (col ~/ 2) + uvRow * (row ~/ 2);
        final yp = y.bytes[row * yRow + col].toDouble();
        final up = u.bytes[uvIndex].toDouble();
        final vp = v.bytes[uvIndex].toDouble();

        int r = (yp + 1.402 * (vp - 128)).round().clamp(0, 255);
        int g = (yp - 0.344136 * (up - 128) - 0.714136 * (vp - 128))
            .round()
            .clamp(0, 255);
        int b = (yp + 1.772 * (up - 128)).round().clamp(0, 255);

        out.setPixelRgb(col, row, r, g, b);
      }
    }
    return out;
  }

  Float32List _normalize(img.Image im, List<double> mean, List<double> std) {
    final w = im.width, h = im.height;
    final out = Float32List(3 * h * w);
    int i = 0;

    for (final p in im) {
      out[i++] = (p.rNormalized - mean[0]) / std[0];
      out[i++] = (p.gNormalized - mean[1]) / std[1];
      out[i++] = (p.bNormalized - mean[2]) / std[2];
    }

    return out;
  }
}

class _PreprocessResult {
  final Float32List imageTensor;
  final Int64List? inputIds;

  _PreprocessResult({required this.imageTensor, this.inputIds});
}

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
