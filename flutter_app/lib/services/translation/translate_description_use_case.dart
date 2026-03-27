import 'package:flutter/foundation.dart';

import 'google_translate_service.dart';

class TranslateDescriptionUseCase {
  final GoogleTranslateService _translator;
  static const Duration _translateDeadline = Duration(milliseconds: 2000);

  static final RegExp _thaiRegex = RegExp(r'[\u0E00-\u0E7F]');
  static const Map<String, String> _canonicalThaiMap = {
    'too dark to see clearly.': 'แสงสว่างไม่เพียงพอ',
    'scene unclear, cannot confirm what is ahead.': 'ไม่สามารถมองเห็นได้ชัดเจน',
    'the path is clear ahead.': 'ทางข้างหน้าโล่ง',
    'the path ahead is clear.': 'ทางข้างหน้าโล่ง',
    'the walkway ahead is clear.': 'ทางข้างหน้าโล่ง',
    'path clear ahead.': 'ทางข้างหน้าโล่ง',
  };

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

    final canonicalThai = _canonicalThaiMap[_normalizeKey(text)];
    if (canonicalThai != null) return canonicalThai;

    try {
      return await _translator
          .translate(
            text: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
          )
          .timeout(_translateDeadline);
    } catch (e) {
      debugPrint('[Translation] fallback to original: $e');
      return text;
    }
  }

  void dispose() {
    _translator.dispose();
  }

  String _normalizeKey(String text) {
    return text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
