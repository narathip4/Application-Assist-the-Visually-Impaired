// lib/app/config.dart
class AppConfig {
  static const String appName = 'VIA';

  static const String _defaultVlmBaseUrl =
      'https://narathip7-fastvlm-space-test.hf.space';

  static const String _promptCore =
      'You are an object detection assistant for a visually impaired person. '
      'Describe the one or two most useful visible objects or obstacles for safe walking in one short factual sentence. '
      'If the walking path is open, still mention clearly visible landmarks or side objects that help with orientation. '
      'Focus first on the nearest objects that could affect walking, not general background scenery. '
      'Include object position whenever it is clearly visible. '
      'Include motion only if it is clearly visible. '
      'User is always on center of the scene, so describe object position relative to the user. '
      'Prefer practical location words like ahead, left, right, nearby, or farther away. '
      'Mention distance such as near or far only if it is clearly visible. ';

  static const String _promptEnvironmentGuidance =
      'If outdoors, focus on the most important clearly visible objects or hazards for safe walking. '
      'Pay special attention to thin vertical obstacles such as poles, posts, signposts, railings, cones, and vehicles when they are clearly visible near the walking path. '
      'If indoors, mention any clearly visible object or landmark forsafe walking. '
      'Pay special attention to furniture, desks, chairs, stairs, doors, and people when they are clearly visible. ';

  static const String _promptHazardRule =
      'If two or more hazards are clearly visible, mention both briefly in the same sentence. '
      'For clear-path scenes, prefer naming visible objects and their position such as "stairs on the right" or "bushes on the left" instead of giving only a generic clear-path statement. '
      'Do not mention any object, hazard, screen, desk, keyboard, or person unless it is clearly visible. ';

  static const String _promptFallbacks =
      'If the scene is too dark to see, say exactly: "Too dark to see clearly." '
      'Only if no meaningful object, obstacle, or landmark position can be identified, say exactly: "The path ahead is clear." '
      'If you can see the scene but are unsure what something is, say exactly: "Scene unclear, cannot confirm what is ahead." ';

  static const String _promptOutputRule =
      'Use plain natural language with no labels, no bullet points, no extra explanation. One sentence only.';

  static const String _defaultPrompt =
      _promptCore +
      _promptEnvironmentGuidance +
      _promptHazardRule +
      _promptFallbacks +
      _promptOutputRule;

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

  static const int jpegMaxSide = 450;
  static const int jpegQuality = 65;

  // --dart-define=VLM_PROMPT=Your prompt here
  static const String prompt = String.fromEnvironment(
    'VLM_PROMPT',
    defaultValue: _defaultPrompt,
  );

  static const String fallbackText = 'กำลังประมวลผลภาพ...';

  // Sequence inference
  static const bool useSequenceInference = true;
  static const int sequenceFrameCount = 5;
  static const int sequenceMaxBufferBytes = 120 * 1024;

  static const Duration inferenceInterval = Duration(milliseconds: 2000);
}
