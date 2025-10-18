// lib/services/gemini_service.dart

import 'dart:typed_data';
import 'package:google_generative_ai/google_generative_ai.dart';

/// A lightweight service for using the Gemini API instead of FastVLM.
/// Plug this into your CameraScreen or any image input flow.
/// No local model or ONNX dependency needed.
class GeminiService {
  final GenerativeModel _model;

  GeminiService({required String apiKey})
    : _model = GenerativeModel(
        model: 'gemini-1.5-flash', // or 'gemini-1.5-pro' for higher accuracy
        apiKey: apiKey,
      );

  /// Sends an image to Gemini and returns its description or analysis text.
  Future<String> analyzeImage(Uint8List imageBytes) async {
    try {
      final response = await _model.generateContent([
        Content.multiModal([
          TextPart('Describe this image.'),
          DataPart('image/jpeg', imageBytes),
        ]),
      ]);
      return response.text?.trim() ?? 'No response from Gemini.';
    } catch (e) {
      return 'Gemini error: $e';
    }
  }

  /// You can extend this for question-based prompts later.
  Future<String> askAboutImage(Uint8List imageBytes, String question) async {
    try {
      final response = await _model.generateContent([
        Content.multiModal([
          TextPart(question),
          DataPart('image/jpeg', imageBytes),
        ]),
      ]);
      return response.text?.trim() ?? 'No response from Gemini.';
    } catch (e) {
      return 'Gemini error: $e';
    }
  }
}
