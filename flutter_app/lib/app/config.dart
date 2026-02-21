// lib/app/config.dart
class AppConfig {
  static const String appName = 'Assist the Visually Impaired';

  // Hugging Face Space base URL
  static const String vlmBaseUrl =
      'https://narathip7-fastvlm-space-test.hf.space';

  // VLM parameters
  // maxNewTokens: Limits response length to keep descriptions concise
  // Lower values = faster responses, but may cut off important details
  static const int maxNewTokens = 32;

  // Image optimization settings
  // jpegMaxSide: Reduces image size for faster processing while maintaining recognition quality
  // jpegQuality: Balances file size against image clarity (60 is a good compromise)
  static const int jpegMaxSide = 360;
  static const int jpegQuality = 60;

  // Prompt for VLM to generate descriptions
  static const String prompt =
      '''You are describing a scene to help a visually impaired person navigate indoor spaces and pedestrian walkways.

Provide a brief, clear description in one to two sentences. Focus on stationary elements and potential obstacles you can identify with certainty.

What to describe:
- Objects and obstacles in the field of view, especially at chest or head height where a cane might not detect them, such as poles, signs, overhanging branches, or furniture
- Architectural features like doors, walls, stairs, ramps, or level changes
- Floor surfaces and any visible hazards like wet floor signs, uneven surfaces, or objects on the ground
- Tactile paving, accessible pathway markings, or other accessibility features
- People or objects that appear to be in or near the walking path

How to describe:
- Use clear spatial terms such as "directly ahead," "to your left," "on the right side," or "at the center of view"
- Describe what you see without claiming to know exact distances in meters or feet
- For potential obstacles, describe what they are and their approximate position, such as "a pole appears in the center of your path" or "stairs descending ahead"
- Use simple, direct language that focuses on what is observable in the image

Safety boundaries:
- Do NOT make claims about whether something is safe to approach or how far away it is in specific measurements
- Do NOT analyze traffic situations, moving vehicles, or road crossings because this system is not designed for those environments
- If the lighting is poor or the image is unclear, state honestly: "The image quality is insufficient for reliable description"
- If you detect what appears to be a road or traffic area, state: "This appears to be a traffic area where this system should not be used"

Describe what you see now:''';

  // User-facing message shown while processing
  // Changed to better reflect the uncertainty inherent in the process
  static const String fallbackText = 'Processing image...';

  // Sequence inference settings
  // When enabled, consecutive frames are combined into one VLM input image.
  static const bool useSequenceInference = true;
  static const int sequenceFrameCount = 3;
  static const String sequencePromptPrefix =
      'These are consecutive frames in time from left to right. '
      'Use temporal consistency to prioritize hazards that are approaching or entering the path. ';

  // Timing configuration
  // inferenceInterval: How often the app captures and processes new images
  // 1200ms (1.2 seconds) balances responsiveness with processing load
  static const Duration inferenceInterval = Duration(milliseconds: 900);
}
