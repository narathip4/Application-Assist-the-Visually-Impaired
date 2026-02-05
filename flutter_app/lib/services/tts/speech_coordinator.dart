import 'package:flutter/foundation.dart';
import 'tts_service.dart';

class SpeechCoordinator {
  final TtsService _tts;

  bool _isSpeaking = false;
  String? _pendingCritical;
  int _lastCriticalStopAtMs = 0;

  SpeechCoordinator({required TtsService tts}) : _tts = tts;

  /// Decide whether message is critical (same logic as before)
  bool isCriticalMessage(String message) {
    final t = message.toLowerCase();

    const keywords = <String>[
      'สิ่งกีดขวาง',
      'กีดขวาง',
      'เสา',
      'บันได',
      'ขั้นบันได',
      'หลุม',
      'ลื่น',
      'ขอบ',
      'ตก',
      'ผนัง',
      'กำแพง',
      'ประตู',
      'รถ',
      'จักรยาน',
      'มอเตอร์ไซค์',
      'คน',
      // English
      'obstacle',
      'pole',
      'stairs',
      'stair',
      'step',
      'hole',
      'slippery',
      'edge',
      'wall',
      'door',
      'car',
      'bike',
      'motorcycle',
      'person',
      'pedestrian',
    ];

    return keywords.any(t.contains);
  }

  /// Speak with priority & interrupt handling (behavior identical to original)
  Future<void> speak(
    String text, {
    required bool isCritical,
    required bool ttsEnabled,
  }) async {
    if (text.trim().isEmpty) return;
    if (!ttsEnabled) return;

    // Critical should interrupt current speech
    if (isCritical && _isSpeaking) {
      _pendingCritical = text;

      final now = DateTime.now().millisecondsSinceEpoch;
      final shouldStopNow = now - _lastCriticalStopAtMs > 400;
      if (shouldStopNow) {
        _lastCriticalStopAtMs = now;
        await _tts.stop();
        _isSpeaking = false;
      }
      return;
    }

    // Drop non-critical if already speaking
    if (_isSpeaking && !isCritical) return;

    _isSpeaking = true;
    try {
      await _tts.speak(text);
    } catch (e) {
      debugPrint('[SpeechCoordinator] TTS error: $e');
    } finally {
      _isSpeaking = false;

      // Speak pending critical (if any)
      final pending = _pendingCritical;
      _pendingCritical = null;
      if (pending != null && ttsEnabled) {
        await speak(pending, isCritical: true, ttsEnabled: ttsEnabled);
      }
    }
  }

  /// Stop everything immediately (used on pause / toggle off)
  Future<void> stop() async {
    _pendingCritical = null;
    _isSpeaking = false;
    await _tts.stop();
  }
}
