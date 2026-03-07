import 'package:flutter/foundation.dart';

import 'google_translate_service.dart';

class TranslateDescriptionUseCase {
  final GoogleTranslateService _translator;

  static final RegExp _thaiRegex = RegExp(r'[\u0E00-\u0E7F]');

  TranslateDescriptionUseCase({required GoogleTranslateService translator})
    : _translator = translator;

  Future<String> execute(
    String rawText, {
    required bool enabled,
    String sourceLanguage = 'en',
    String targetLanguage = 'th',
  }) async {
    final text = rawText.trim();
    if (text.isEmpty || !enabled) return text;
    if (_thaiRegex.hasMatch(text)) return text;

    try {
      return await _translator.translate(
        text: text,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
      );
    } catch (e) {
      debugPrint('[Translation] fallback to original: $e');
      return text;
    }
  }

  void dispose() {
    _translator.dispose();
  }
}
