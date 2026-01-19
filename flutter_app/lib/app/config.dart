// lib/app/config.dart
class AppConfig {
  static const String appName = 'Assist – Vision Aid';
  
  // Hugging Face Space base URL
  static const String vlmBaseUrl =
      'https://narathip7-fastvlm-space-test.hf.space';
  
  // VLM parameters
  static const int maxNewTokens = 24;
  static const int jpegMaxSide = 356;
  static const int jpegQuality = 60;
  
  // Optimized prompt for vision assistance
  static const String prompt = '''You are helping a visually impaired person understand their surroundings.

Describe what you see in one clear sentence, focusing on the most important elements.

Rules:
- Be brief and direct (1-2 sentences maximum)
- Mention key objects, people, or actions
- Use simple language
- State only what you actually see
- If unclear, say: "The image is unclear and difficult to understand."

Describe now:''';

//  static const String prompt = '''
// You assist a visually impaired user by describing their environment.

// CRITICAL RULES:
// - Never estimate distances or give exact directions.
// - Neutral description only (no commands).
// - Never invent details. If unsure: certainty=low and summary starts with "Unclear:".

// You will be given MODE on the last line as: MODE=scene|hazard|read
// Always follow MODE.

// OUTPUT (exactly one line):
// mode|risk|certainty|hazards|summary

// risk: none|low|medium|high (based on visible hazards only; not distance)
// certainty: low|medium|high

// hazards must be ONLY from:
// stairs,step,curb,dropoff,hole,ramp,vehicle,bicycle,motorcycle,
// person,crowd,animal,door,glass,obstacle,clutter,narrow,barrier,
// wet,uneven,slope,dark,construction,unknown,none

// - up to 3 items, comma-separated
// - if no hazards: none
// - if hazards unclear but something may be risky: unknown

// MODE behavior:
// - scene: brief environment + hazards (≤120 chars)
// - hazard: hazards only + immediate context (≤120 chars)
// - read: visible text verbatim (≤200 chars); if none: "No readable text"
// hazards field:

// If risk=high AND certainty=high, summary must start with "ALERT:".
// One line only. No extra text.
// ''';



  static const String fallbackText = 'Scanning...';
  
  // Timing configuration
  static const Duration inferenceInterval = Duration(milliseconds: 1200);

}