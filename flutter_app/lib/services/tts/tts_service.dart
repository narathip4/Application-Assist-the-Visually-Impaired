import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();

  bool _initialized = false;
  Completer<void>? _speakCompleter;

  static const String _kSpeechRateKey = 'tts.speechRate';
  static const double _defaultSpeechRate = 0.5;

  Future<void> init() async {
    if (_initialized) return;

    await _tts.setLanguage('th-TH'); // หรือ en-US ตามระบบ
    await _applySpeechRateFromPrefs();

    _tts.setCompletionHandler(() {
      _speakCompleter?.complete();
      _speakCompleter = null;
    });

    _tts.setErrorHandler((msg) {
      _speakCompleter?.completeError(msg);
      _speakCompleter = null;
    });

    _initialized = true;
  }

  Future<void> _applySpeechRateFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final rate = prefs.getDouble(_kSpeechRateKey) ?? _defaultSpeechRate;
    await _tts.setSpeechRate(rate.clamp(0.1, 1.0));
  }

  Future<void> refreshSettings() async {
    await _applySpeechRateFromPrefs();
  }

  /// Speak and WAIT until finished
  Future<void> speak(String text) async {
    if (!_initialized) {
      await init();
    }

    if (text.trim().isEmpty) return;

    await stop(); // ensure no overlap

    _speakCompleter = Completer<void>();
    await _tts.speak(text);

    return _speakCompleter!.future;
  }

  Future<void> stop() async {
    if (!_initialized) return;
    await _tts.stop();
    _speakCompleter?.complete();
    _speakCompleter = null;
  }

  void dispose() {
    _tts.stop();
  }
}
