// lib/app/config.dart
class AppConfig {
  static const String appName = 'VIA';

  static const String _defaultVlmBaseUrl =
      'https://narathip7-fastvlm-space-test.hf.space';

  static const String _defaultPrompt =
      'You are a walking assistant for a visually impaired person. '
      'Describe object and environment in a one short factual sentence. '
      'Include position and motion only if they are clearly visible. '
      'And also far or near if it is clearly visible. '
      'If the scene is too dark to see, say exactly: '
      '"Too dark to see clearly." '
      'Do not mention any object, hazard, screen, desk, keyboard, or person '
      'unless it is clearly visible. '
      'If the walking path looks open and there is no important nearby hazard, '
      'say exactly: "The path ahead is clear." '
      'If you can see the scene but are unsure what something is, say exactly: '
      '"Scene unclear, cannot confirm what is ahead." '
      'Use plain natural language with no labels, no bullet points, '
      'No extra explanation. One sentence only.';

  // --dart-define=VLM_BASE_URL=https://api
  static const String vlmBaseUrl = String.fromEnvironment(
    'VLM_BASE_URL',
    defaultValue: _defaultVlmBaseUrl,
  );

  // --dart-define=VLM_MAX_NEW_TOKENS=40
  static const int maxNewTokens = int.fromEnvironment(
    'VLM_MAX_NEW_TOKENS',
    defaultValue: 32,
  );

  // --dart-define=VLM_REQUEST_TIMEOUT_SECONDS=20
  static const int vlmRequestTimeoutSeconds = int.fromEnvironment(
    'VLM_REQUEST_TIMEOUT_SECONDS',
    defaultValue: 20,
  );
  static const Duration vlmRequestTimeout = Duration(
    seconds: vlmRequestTimeoutSeconds,
  );

  static const int jpegMaxSide = 320;
  static const int jpegQuality = 50;

  // --dart-define=VLM_PROMPT=Your prompt here
  static const String prompt = String.fromEnvironment(
    'VLM_PROMPT',
    defaultValue: _defaultPrompt,
  );

  static const String fallbackText = 'กำลังประมวลผลภาพ...';

  // Sequence inference
  static const bool useSequenceInference = true;
  static const int sequenceFrameCount = 3;
  static const int sequenceMaxBufferBytes = 120 * 1024;

  static const Duration inferenceInterval = Duration(milliseconds: 2000);
}
