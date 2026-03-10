// lib/app/config.dart
class AppConfig {
  static const String appName = 'ผู้ช่วยการมองเห็น';

  // Hugging Face Space base URL
  static const String vlmBaseUrl =
      'https://narathip7-fastvlm-space-test.hf.space';

  // VLM parameters
  // maxNewTokens: Limits response length to keep descriptions concise
  // Lower values = faster responses, but may cut off important details
  static const int maxNewTokens = 48;

  // Image optimization settings
  // jpegMaxSide: Reduces image size for faster processing while maintaining recognition quality
  // jpegQuality: Balances file size against image clarity (60 is a good compromise)
  static const int jpegMaxSide = 360;
  static const int jpegQuality = 60;

  // Single default safety prompt (used in all inference runs).
  // Keep one concise sentence for clear TTS playback.
  static const String safetyPrompt = '''
You are a real-time safety assistant for a visually impaired user.

Return exactly ONE short spoken sentence (8-16 words).
Focus only on immediate walking safety.

Rules:
- Mention only the highest-risk object or hazard.
- Include one position word: ahead, left, right, or center.
- Include movement if visible: approaching, crossing, or stationary.
- Use "Careful," for hazards.
- Use neutral wording if no immediate hazard.
- No distances or measurements.
- No extra explanation.
- No chatbot/polite phrases (never say: "I hope this helps", "let me know", "anything else").
- Output one sentence only.
''';

  // User-facing message shown while processing
  // Changed to better reflect the uncertainty inherent in the process
  static const String fallbackText = 'กำลังประมวลผลภาพ...';

  // Sequence inference settings
  // When enabled, consecutive frames are combined into one VLM input image.
  static const bool useSequenceInference = true;
  static const int sequenceFrameCount = 3;
  // Timing configuration
  // inferenceInterval: How often the app captures and processes new images
  // 1200ms (1.2 seconds) balances responsiveness with processing load
  static const Duration inferenceInterval = Duration(milliseconds: 1200);
}
