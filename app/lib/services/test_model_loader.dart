// import 'dart:io';
// import 'package:path_provider/path_provider.dart';

// Future<void> testModelIntegrity() async {
//   final dir = await getApplicationDocumentsDirectory();
//   final modelPath = '${dir.path}/models/FastVLM-0.5B-ONNX';
//   final files = {
//     'vision_encoder.onnx': 215 * 1024 * 1024,
//     'embed_tokens.onnx': 25 * 1024 * 1024,
//     'decoder_model_merged.onnx': 900 * 1024 * 1024,
//     'tokenizer.json': 1 * 1024 * 1024,
//     'preprocessor_config.json': 500,
//     'special_tokens_map.json': 500,
//     'generation_config.json': 500,
//     'tokenizer_config.json': 500,
//   };

//   print('Checking model files in: $modelPath');
//   bool allOk = true;

//   for (final entry in files.entries) {
//     final file = File('$modelPath/${entry.key}');
//     if (await file.exists()) {
//       final size = await file.length();
//       final minSize = entry.value;
//       if (size >= minSize) {
//         print(
//           '${entry.key} â†’ ${(size / (1024 * 1024)).toStringAsFixed(2)} MB',
//         );
//       } else {
//         print(
//           '${entry.key} too small: ${(size / (1024 * 1024)).toStringAsFixed(2)} MB < ${(minSize / (1024 * 1024)).toStringAsFixed(2)} MB',
//         );
//         allOk = false;
//       }
//     } else {
//       print('Missing: ${entry.key}');
//       allOk = false;
//     }
//   }

//   print(
//     allOk ? 'All model files verified.' : 'Some files missing or incomplete.',
//   );
// }
