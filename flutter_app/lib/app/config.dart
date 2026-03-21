// lib/app/config.dart
class AppConfig {
  static const String appName = 'ผู้ช่วยการมองเห็น';

  // Hugging Face Space base URL
  static const String vlmBaseUrl =
      'https://narathip7-fastvlm-space-test.hf.space';

  // VLM parameters
  static const int maxNewTokens = 32;
  // Image optimization settings
  static const int jpegMaxSide = 320;
  static const int jpegQuality = 55;

  // parrot the instruction text back as the answer.
  static const String prompt =
      'You are a walking assistant for a visually impaired person. '
      'Describe the most important nearby hazard or object in one short sentence. '
      'Include one position word if visible: ahead, left, right, or center. '
      'Start with "Danger," only for immediate hazards. '
      'If there is no important hazard, say "Path clear ahead." '
      'No extra explanation. One sentence only.';

  // User-facing message shown while processing
  static const String fallbackText = 'กำลังประมวลผลภาพ...';

  // Sequence inference
  static const bool useSequenceInference = true;
  static const int sequenceFrameCount = 3;

  // Keep the capture cadence aligned with real server latency to reduce
  static const Duration inferenceInterval = Duration(milliseconds: 1200);
}
