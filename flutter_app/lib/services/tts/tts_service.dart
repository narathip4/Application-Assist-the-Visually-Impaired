import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();

  bool _initialized = false;
  String? _currentLang; // 'th-TH' / 'en-US'

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);

    // Optional: await _tts.awaitSpeakCompletion(true);
  }

  Future<void> stop() => _tts.stop();

  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    await init();

    // auto language
    final lang = _detectLang(text);
    if (_currentLang != lang) {
      _currentLang = lang;
      await _tts.setLanguage(lang);
    }

    await _tts.speak(text);
  }

  String _detectLang(String text) {
    final isThai = RegExp(r'[ก-๙]').hasMatch(text);
    return isThai ? 'th-TH' : 'en-US';
  }

  void dispose() {
    _tts.stop();
  }
}
