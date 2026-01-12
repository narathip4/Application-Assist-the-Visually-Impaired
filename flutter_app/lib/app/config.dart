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
Describe what is visible in the image in one neutral sentence.
Respond concisely and clearly, focusing on key details relevant for a visually impaired user. 
''';

  static const String fallbackText = 'Clear ahead.';

  // Throttling (near real-time)
  static const Duration inferenceInterval = Duration(milliseconds: 700);
}
