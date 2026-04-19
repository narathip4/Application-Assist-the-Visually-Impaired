import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();

  bool _initialized = false;
  bool _isSpeaking = false;
  Completer<void>? _speakCompleter;
  String? _currentLanguage;
  String? _activeTraceId;
  int? _activeInputAcceptedAtMs;

  static const String _kSpeechRateKey = 'tts.speechRate';
  static const double _defaultSpeechRate = 0.85;
  static final RegExp _thaiRegex = RegExp(r'[\u0E00-\u0E7F]');

  Future<void> init() async {
    if (_initialized) return;

    await _tts.awaitSpeakCompletion(true);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    await _configureLanguage();
    await _applySpeechRateFromPrefs();

    _tts.setStartHandler(() {
      _isSpeaking = true;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (_activeTraceId != null && _activeInputAcceptedAtMs != null) {
        final deltaMs = nowMs - _activeInputAcceptedAtMs!;
        // ignore: avoid_print
        print(
          '[METRIC] trace=${_activeTraceId!} '
          'tts_ms=$deltaMs',
        );
      }
      // ignore: avoid_print
      print('[TTS] start trace=${_activeTraceId ?? "-"}');
    });

    _tts.setCompletionHandler(() {
      _isSpeaking = false;
      _activeTraceId = null;
      _activeInputAcceptedAtMs = null;
      _speakCompleter?.complete();
      _speakCompleter = null;
    });

    _tts.setErrorHandler((msg) {
      _isSpeaking = false;
      _activeTraceId = null;
      _activeInputAcceptedAtMs = null;
      _speakCompleter?.completeError(msg);
      _speakCompleter = null;
    });

    _initialized = true;
  }

  Future<void> _configureLanguage() async {
    final thaiReady = await _trySetLanguage('th-TH');
    if (!thaiReady) {
      // Fallback when Thai voice pack is missing on device/emulator.
      await _trySetLanguage('en-US');
    }
  }

  Future<bool> _trySetLanguage(String languageCode) async {
    final result = await _tts.setLanguage(languageCode);
    final ok = result == 1 || result == true;
    if (ok) {
      _currentLanguage = languageCode;
    }
    return ok;
  }

  Future<void> _setLanguageForText(String text) async {
    final preferredLanguage = _thaiRegex.hasMatch(text) ? 'th-TH' : 'en-US';
    if (_currentLanguage == preferredLanguage) return;

    final ready = await _trySetLanguage(preferredLanguage);
    if (!ready && preferredLanguage != 'en-US') {
      await _trySetLanguage('en-US');
    }
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
  Future<void> speak(
    String text, {
    String? traceId,
    int? inputAcceptedAtMs,
  }) async {
    if (!_initialized) {
      await init();
    }

    if (text.trim().isEmpty) return;

    if (_isSpeaking || _speakCompleter != null) {
      await stop();
    }
    await _setLanguageForText(text);

    _activeTraceId = traceId;
    _activeInputAcceptedAtMs = inputAcceptedAtMs;
    _speakCompleter = Completer<void>();
    final speakFuture = _speakCompleter!.future;
    // ignore: avoid_print
    print('[TTS] queue="${_shortLogText(text)}"');
    await _tts.speak(text);

    return speakFuture;
  }

  Future<void> stop() async {
    if (!_initialized) return;
    await _tts.stop();
    _isSpeaking = false;
    _activeTraceId = null;
    _activeInputAcceptedAtMs = null;
    _speakCompleter?.complete();
    _speakCompleter = null;
  }

  void dispose() {
    _isSpeaking = false;
    _activeTraceId = null;
    _activeInputAcceptedAtMs = null;
    _tts.stop();
  }

  String _shortLogText(String text, {int max = 72}) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= max) return normalized;
    return '${normalized.substring(0, max - 3)}...';
  }
}
