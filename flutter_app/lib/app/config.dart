class AppConfig {
  static const String appName = 'Assist – Vision Aid';

  // Hugging Face Space (ตัวที่ใช้งานได้จริง)
  static const String vlmBaseUrl =
      'https://narathip7-fastvlm-space-test.hf.space';

  // VLM defaults
  static const int maxNewTokens = 24;
  static const int jpegMaxSide = 512;
  static const int jpegQuality = 70;

  static const String prompt = '''
You are assisting a visually impaired user.
Reply with ONE short sentence only.
Describe nearby obstacles directly in front of the camera that the user may bump into (e.g., wall, door, person, chair, steps).
If nothing is close, reply exactly: "Clear ahead."
No refusal. No extra text.
''';

  static const String fallbackText = 'Clear ahead.';

  // Throttling (near real-time)
  static const Duration inferenceInterval = Duration(milliseconds: 900);
}
