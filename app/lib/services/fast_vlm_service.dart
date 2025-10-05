// import 'dart:async';
// import 'dart:typed_data';
// import 'package:camera/camera.dart';
// import 'package:image/image.dart' as img;
// import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

// import 'model_loader.dart';

// class FastVlmService {
//   OrtSession? _visionSession;
//   OrtSession? _embedSession;
//   OrtSession? _decoderSession;
//   Completer<void>? _initCompleter;

//   bool get isReady =>
//       _visionSession != null &&
//       _embedSession != null &&
//       _decoderSession != null;

//   Future<void> ensureInitialized() async {
//     if (isReady) return;
//     if (_initCompleter != null) return _initCompleter!.future;

//     final c = _initCompleter = Completer<void>();
//     try {
//       // 1) à¹ƒà¸«à¹‰ model_loader à¸”à¸²à¸§à¸™à¹Œà¹‚à¸«à¸¥à¸”+à¸„à¸·à¸™à¸žà¸²à¸˜à¹ƒà¸«à¹‰à¸„à¸£à¸š (FP16)
//       await ModelLoader.ensureModelsDownloaded();
//       final paths = await ModelLoader.getAllModelPaths();

//       final ort =
//           OnnxRuntime(); // ORT 1.22.0 (à¸œà¹ˆà¸²à¸™ flutter_onnxruntime â‰¥1.5.1)

//       _visionSession = await ort.createSession(
//         paths['vision_encoder_fp16.onnx']!,
//       );
//       _embedSession = await ort.createSession(paths['embed_tokens_fp16.onnx']!);
//       _decoderSession = await ort.createSession(
//         paths['decoder_model_merged_fp16.onnx']!,
//       );

//       c.complete();
//     } catch (e, st) {
//       c.completeError(e, st);
//       rethrow;
//     } finally {
//       _initCompleter = null;
//     }
//   }

//   /// à¸£à¸±à¸™à¸„à¸£à¸š pipeline à¹€à¸žà¸·à¹ˆà¸­à¸¢à¸·à¸™à¸¢à¸±à¸™à¸§à¹ˆà¸²à¹‚à¸¡à¹€à¸”à¸¥à¸—à¸³à¸‡à¸²à¸™à¸ˆà¸£à¸´à¸‡
//   /// (à¸¢à¸±à¸‡à¹„à¸¡à¹ˆà¸–à¸­à¸”à¸£à¸«à¸±à¸ª token à¹€à¸›à¹‡à¸™à¸‚à¹‰à¸­à¸„à¸§à¸²à¸¡)
//   Future<String> describeCameraImage(
//     CameraImage frame, {
//     String prompt = "Describe scene in Thai",
//   }) async {
//     await ensureInitialized();
//     if (!isReady) throw StateError('FastVLM not ready');

//     // preprocess
//     final pre = _preprocess(
//       image: frame,
//       targetSize: 384,
//       mean: const [0.48145466, 0.4578275, 0.40821073],
//       std: const [0.26862954, 0.26130258, 0.27577711],
//       prompt: prompt,
//     );

//     OrtValue? pixelTensor;
//     OrtValue? idsTensor;
//     OrtValue? maskTensor;

//     Map<String, OrtValue>? vOut;
//     Map<String, OrtValue>? eOut;
//     Map<String, OrtValue>? dOut;

//     try {
//       // FP16 à¹‚à¸¡à¹€à¸”à¸¥à¸ªà¹ˆà¸§à¸™à¹ƒà¸«à¸à¹ˆà¸£à¸±à¸š input float32 à¹„à¸”à¹‰ (weights à¹€à¸›à¹‡à¸™ fp16 à¸ à¸²à¸¢à¹ƒà¸™)
//       pixelTensor = await OrtValue.fromList(pre.imageTensor, [1, 3, 384, 384]);
//       idsTensor = await OrtValue.fromList(pre.inputIds!, [
//         1,
//         pre.sequenceLength!,
//       ]);
//       maskTensor = await OrtValue.fromList(pre.attentionMask!, [
//         1,
//         pre.sequenceLength!,
//       ]);

//       // 1) vision encoder
//       vOut = await _visionSession!.run({'pixel_values': pixelTensor});
//       final enc = vOut.values.first;

//       // 2) embed prompt
//       eOut = await _embedSession!.run({'input_ids': idsTensor});
//       final emb = eOut.values.first;

//       // 3) decoder
//       dOut = await _decoderSession!.run({
//         'encoder_hidden_states': enc,
//         'input_embeddings': emb,
//         'attention_mask': maskTensor,
//       });

//       // à¸£à¸²à¸¢à¸‡à¸²à¸™à¸ªà¸£à¸¸à¸› (à¸ªà¸³à¸«à¸£à¸±à¸šà¹€à¸Šà¹‡à¸à¸§à¹ˆà¸²à¹‚à¸¡à¹€à¸”à¸¥à¸§à¸´à¹ˆà¸‡à¸ˆà¸£à¸´à¸‡)
//       String shape(OrtValue v) => v.shape?.join('x') ?? '?';
//       final visionShape = shape(vOut.values.first);
//       final embedShape = shape(eOut.values.first);
//       final decKey = dOut.keys.isNotEmpty ? dOut.keys.first : 'output';
//       final decShape = shape(dOut.values.first);

//       return 'âœ… Inference OK\n'
//           '- vision: $visionShape\n'
//           '- embed:  $embedShape\n'
//           '- $decKey: $decShape\n'
//           '(*à¸¢à¸±à¸‡à¹„à¸¡à¹ˆà¸–à¸­à¸”à¸£à¸«à¸±à¸ª token â†’ à¸‚à¹‰à¸­à¸„à¸§à¸²à¸¡)';
//     } finally {
//       // cleanup inputs
//       await pixelTensor?.dispose();
//       await idsTensor?.dispose();
//       await maskTensor?.dispose();

//       // cleanup outputs
//       Future<void> disposeMap(Map<String, OrtValue>? m) async {
//         if (m == null) return;
//         for (final v in m.values) {
//           await v.dispose();
//         }
//       }

//       await disposeMap(vOut);
//       await disposeMap(eOut);
//       await disposeMap(dOut);
//     }
//   }

//   Future<void> dispose() async {
//     await _visionSession?.close();
//     await _embedSession?.close();
//     await _decoderSession?.close();
//     _visionSession = _embedSession = _decoderSession = null;
//   }

//   // ---------- Preprocess ----------

//   _PreprocessResult _preprocess({
//     required CameraImage image,
//     required int targetSize,
//     required List<double> mean,
//     required List<double> std,
//     required String prompt,
//   }) {
//     final rgb = _yuv420ToRgb(image);
//     final resized = img.copyResize(
//       rgb,
//       width: targetSize,
//       height: targetSize,
//       interpolation: img.Interpolation.cubic,
//     );
//     final Float32List pixels = _normalize(resized, mean, std);

//     // NOTE: à¸¢à¸±à¸‡à¹„à¸¡à¹ˆà¸¡à¸µ tokenizer à¸ˆà¸£à¸´à¸‡ â€” à¸ªà¸£à¹‰à¸²à¸‡ input ids à¸«à¸¥à¸­à¸à¹€à¸žà¸·à¹ˆà¸­à¹ƒà¸«à¹‰à¸à¸£à¸²à¸Ÿà¸£à¸±à¸™à¹„à¸”à¹‰
//     final toks = prompt.trim().split(RegExp(r'\s+'));
//     final ids = Int64List(toks.length);
//     final mask = Int64List(toks.length);
//     for (int i = 0; i < toks.length; i++) {
//       ids[i] = i + 1; // placeholder
//       mask[i] = 1;
//     }

//     return _PreprocessResult(
//       imageTensor: pixels,
//       inputIds: ids,
//       attentionMask: mask,
//     );
//   }

//   img.Image _yuv420ToRgb(CameraImage image) {
//     final w = image.width, h = image.height;
//     final out = img.Image(width: w, height: h);

//     final y = image.planes[0];
//     final u = image.planes[1];
//     final v = image.planes[2];

//     final yRow = y.bytesPerRow;
//     final uvRow = u.bytesPerRow;
//     final uvPix = u.bytesPerPixel!;

//     for (int row = 0; row < h; row++) {
//       for (int col = 0; col < w; col++) {
//         final uvIndex = uvPix * (col ~/ 2) + uvRow * (row ~/ 2);
//         final yp = y.bytes[row * yRow + col].toDouble();
//         final up = u.bytes[uvIndex].toDouble();
//         final vp = v.bytes[uvIndex].toDouble();

//         int r = (yp + 1.402 * (vp - 128)).round();
//         int g = (yp - 0.344136 * (up - 128) - 0.714136 * (vp - 128)).round();
//         int b = (yp + 1.772 * (up - 128)).round();

//         if (r < 0)
//           r = 0;
//         else if (r > 255)
//           r = 255;
//         if (g < 0)
//           g = 0;
//         else if (g > 255)
//           g = 255;
//         if (b < 0)
//           b = 0;
//         else if (b > 255)
//           b = 255;

//         out.setPixelRgb(col, row, r, g, b);
//       }
//     }
//     return out;
//   }

//   Float32List _normalize(img.Image im, List<double> mean, List<double> std) {
//     final w = im.width, h = im.height;
//     final buf = Float32List(w * h * 3);

//     // CHW
//     int rOff = 0;
//     int gOff = w * h;
//     int bOff = w * h * 2;

//     for (int y = 0; y < h; y++) {
//       for (int x = 0; x < w; x++) {
//         final p = im.getPixel(x, y);
//         final r = p.rNormalized.toDouble();
//         final g = p.gNormalized.toDouble();
//         final b = p.bNormalized.toDouble();

//         buf[rOff++] = (r - mean[0]) / std[0];
//         buf[gOff++] = (g - mean[1]) / std[1];
//         buf[bOff++] = (b - mean[2]) / std[2];
//       }
//     }
//     return buf;
//   }
// }

// class _PreprocessResult {
//   const _PreprocessResult({
//     required this.imageTensor,
//     this.inputIds,
//     this.attentionMask,
//   });

//   final Float32List imageTensor;
//   final Int64List? inputIds;
//   final Int64List? attentionMask;

//   int? get sequenceLength => inputIds?.length;
// }
