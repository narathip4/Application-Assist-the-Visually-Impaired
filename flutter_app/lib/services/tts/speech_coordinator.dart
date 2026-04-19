import 'package:flutter/foundation.dart';
import 'tts_service.dart';

enum HazardPriority { clear, awareness, critical }

class SpeechDecision {
  final HazardPriority priority;
  final bool isCritical;
  final bool allowSpeak;
  const SpeechDecision({
    required this.priority,
    required this.isCritical,
    required this.allowSpeak,
  });
}

class SpeechCoordinator {
  final TtsService _tts;

  bool _isSpeaking = false;
  bool _activeIsCritical = false;
  String? _activeTextKey;
  String? _lastCriticalTextKey;
  int _lastCriticalSpokenAtMs = 0;
  int _activeSpeechSessionId = 0;

  static const int _criticalRepeatSuppressMs = 1500;
  static const Duration _softEscalationWindow = Duration(milliseconds: 3800);
  static const String _softKindPerson = 'person';

  final Map<String, List<int>> _softHitsMs = {};

  SpeechCoordinator({required TtsService tts}) : _tts = tts;

  // Hazard keyword lists

  static const List<String> _immediateInfrastructureHazards = [
    'บันได',
    'ขั้นบันได',
    'บันไดเลื่อน',
    'หลุม',
    'หลุมก่อสร้าง',
    'ฝาท่อ',
    'ลื่น',
    'ผนัง',
    'กำแพง',
    'เสา',
    'เสาไฟฟ้า',
    'เสาอากาศ',
    'ประตู',
    'ประตูอัตโนมัติ',
    'กระจก',
    'สิ่งกีดขวาง',
    'กีดขวาง',
    'ป้ายจราจร',
    'ทางลาด',
    'ท่อระบายน้ำ',
    'โซ่กั้น',
    'เชือกกั้น',
    'กรวยจราจร',
    'นั่งร้าน',
    'แผงลอย',
    'stairs',
    'stair',
    'step',
    'escalator',
    'hole',
    'construction pit',
    'manhole',
    'slippery',
    'wall',
    'pole',
    'pillar',
    'power pole',
    'door',
    'automatic door',
    'glass',
    'obstacle',
    'sign',
    'traffic sign',
    'ramp',
    'drain',
    'chain barrier',
    'rope barrier',
    'traffic cone',
    'street vendor',
    'food stall',
  ];
  static const List<String> _contextualInfrastructureHazards = [
    'ขอบ',
    'ขอบทาง',
    'edge',
    'curb',
  ];

  static const List<String> _vehicleHazards = [
    'รถยนต์',
    'รถบรรทุก',
    'รถกระบะ',
    'รถโดยสาร',
    'มอเตอร์ไซค์',
    'รถจักรยานยนต์',
    'จักรยาน',
    'car',
    'truck',
    'pickup truck',
    'bus',
    'motorcycle',
    'motorbike',
    'vehicle',
    'bike',
    'bicycle',
  ];
  static const List<String> _vehicleCriticalCues = [
    'เข้าใกล้',
    'กำลังเข้าใกล้',
    'เคลื่อนที่',
    'กำลังเคลื่อนที่',
    'วิ่งมา',
    'ขับมา',
    'ตัดหน้า',
    'ขวางทาง',
    'ขวางหน้า',
    'approaching',
    'moving',
    'coming toward',
    'driving toward',
    'crossing',
    'blocking',
    'in your path',
  ];
  static const List<String> _animalHazards = [
    'สุนัข',
    'แมว',
    'สัตว์',
    'dog',
    'cat',
    'animal',
  ];

  static const List<String> _movingObjects = ['รถเข็น', 'cart'];

  static const List<String> _softHazardsTh = ['คน'];
  static const List<String> _softHazardsEn = [
    'person',
    'pedestrian',
    'wheelchair',
  ];
  static const List<String> _softCriticalCues = [
    'ตรงหน้า',
    'ใกล้มาก',
    'กำลังเข้าใกล้',
    'ตัดหน้า',
    'ขวางทาง',
    'ขวางหน้า',
    'ชิด',
    'ติด',
    'in front',
    'very close',
    'approaching',
    'in your path',
    'crossing',
    'blocking',
  ];

  static const Map<String, String> _softHazardCategoryTh = {
    'คน': _softKindPerson,
  };
  static const Map<String, String> _softHazardCategoryEn = {
    'person': _softKindPerson,
    'pedestrian': _softKindPerson,
    'wheelchair': _softKindPerson,
  };

  static const List<String> _navigationAids = [
    'ทางม้าลาย',
    'ม้าลาย',
    'ทางข้าม',
    'ไฟจราจร',
    'สัญญาณไฟ',
    'สัญญาณเสียง',
    'ป้ายรถเมล์',
    'ป้ายรถ',
    'ทางลาดผู้พิการ',
    'ราวจับ',
    'แผ่นนูน',
    'จุดนูน',
    'แนวกระเบื้องนูน',
    'เส้นนำทาง',
    'ทางเท้า',
    'crosswalk',
    'zebra crossing',
    'pedestrian crossing',
    'traffic light',
    'signal',
    'audio signal',
    'bus stop',
    'handrail',
    'tactile paving',
    'tactile strip',
    'guide path',
    'sidewalk',
    'pavement',
  ];

  static const List<String> _directionalCues = [
    'ซ้าย',
    'ขวา',
    'หลัง',
    'ซ้ายมือ',
    'ขวามือ',
    'ด้านซ้าย',
    'ด้านขวา',
    'เลี้ยวซ้าย',
    'เลี้ยวขวา',
    'ตรงไป',
    'left',
    'right',
    'front',
    'behind',
    'back',
    'left side',
    'right side',
    'turn left',
    'turn right',
    'straight',
    'ahead',
  ];

  static const List<String> _surfaceConditions = [
    'เปียก',
    'น้ำขัง',
    'ลื่น',
    'ขรุขระ',
    'ไม่เรียบ',
    'หลุมบ่อ',
    'หิน',
    'ทราย',
    'โคลน',
    'หญ้า',
    'ปูน',
    'กระเบื้อง',
    'wet',
    'water',
    'slippery',
    'rough',
    'uneven',
    'pothole',
    'gravel',
    'sand',
    'mud',
    'grass',
    'concrete',
    'tiles',
  ];

  static const List<String> _nearCues = [
    'ข้างหน้า',
    'ตรงหน้า',
    'ด้านหน้า',
    'ใกล้',
    'ใกล้มาก',
    'เข้าใกล้',
    'กำลังเข้าใกล้',
    'ตัดหน้า',
    'ขวางทาง',
    'ขวางหน้า',
    'ชิด',
    'ติด',
    'in front',
    'ahead',
    'near',
    'close',
    'very close',
    'approaching',
    'in your path',
    'crossing',
    'blocking',
    'nearby',
  ];

  static const List<String> _clearPhrases = [
    'clear ahead',
    'is clear',
    'ahead is clear',
    'the path is clear ahead',
    'the walkway ahead is clear',
    'clear path ahead',
    'ข้างหน้าโล่ง',
    'ข้างหน้าโล่ง เดินต่อได้',
    'ข้างหน้าปลอดโปร่ง',
    'ทางข้างหน้าปลอดภัย',
    'ทางด้านหน้าโล่ง',
    'เส้นทางข้างหน้าโล่ง',
  ];
  static const List<String> _lowVisibilityPhrases = [
    'too dark to see clearly',
    'scene unclear, cannot confirm what is ahead',
    'แสงสว่างไม่เพียงพอ',
    'ไม่สามารถมองเห็นได้ชัดเจน',
  ];
  static const List<String> _noHazardPhrases = [
    'no immediate hazards',
    'no visible hazards',
    'no hazards visible',
    'clear of any obstacles or hazards',
    'no obstacles or hazards',
    'nothing blocking the path',
    'ไม่มีอันตราย',
    'ไม่มีสิ่งกีดขวาง',
    'ไม่มีอันตรายใดๆ',
    'ไม่มีสิ่งกีดขวางหรืออันตรายใดๆ',
    'ไม่สามารถมองเห็นอันตรายในทันทีได้',
  ];

  // Public API

  SpeechDecision evaluate(String message) =>
      _evaluateInternal(message, recordSoftSequenceHit: true);

  Future<void> speak(
    String text, {
    required bool isCritical,
    required bool ttsEnabled,
    String? traceId,
    int? inputAcceptedAtMs,
  }) async {
    if (text.trim().isEmpty || !ttsEnabled) return;

    final normalized = _normalizeTextKey(text);
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    if (isCritical) {
      final isRepeatedCritical =
          _lastCriticalTextKey == normalized &&
          nowMs - _lastCriticalSpokenAtMs < _criticalRepeatSuppressMs;
      if (isRepeatedCritical) return;

      final isSameCriticalActive =
          _isSpeaking && _activeIsCritical && _activeTextKey == normalized;
      if (isSameCriticalActive) return;

      // Let an active critical sentence finish instead of cutting it off
      // with a slightly different critical rephrase on the next frame.
      if (_isSpeaking && _activeIsCritical) {
        return;
      }

      if (_isSpeaking) {
        await _tts.stop();
        _isSpeaking = false;
      }
    }

    if (_isSpeaking && !isCritical) return;

    final sessionId = ++_activeSpeechSessionId;
    _isSpeaking = true;
    _activeIsCritical = isCritical;
    _activeTextKey = normalized;

    if (isCritical) {
      _lastCriticalTextKey = normalized;
      _lastCriticalSpokenAtMs = nowMs;
    }

    try {
      await _tts.speak(
        text,
        traceId: traceId,
        inputAcceptedAtMs: inputAcceptedAtMs,
      );
    } catch (e) {
      debugPrint('[SpeechCoordinator] TTS error: $e');
    } finally {
      if (_activeSpeechSessionId == sessionId) {
        _isSpeaking = false;
        _activeIsCritical = false;
        _activeTextKey = null;
      }
    }
  }

  Future<void> stop() async {
    _activeSpeechSessionId++;
    _isSpeaking = false;
    _activeIsCritical = false;
    _activeTextKey = null;
    await _tts.stop();
  }

  // Evaluation logic

  SpeechDecision _evaluateInternal(
    String message, {
    required bool recordSoftSequenceHit,
  }) {
    final t = message.toLowerCase();
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    if (_looksLikeLowVisibilityPhrase(t)) {
      return const SpeechDecision(
        priority: HazardPriority.awareness,
        isCritical: false,
        allowSpeak: true,
      );
    }

    if (_looksLikeClearPhrase(t)) {
      return const SpeechDecision(
        priority: HazardPriority.clear,
        isCritical: false,
        allowSpeak: true,
      );
    }

    if (_looksLikeSafeOpenPathContext(t)) {
      return const SpeechDecision(
        priority: HazardPriority.clear,
        isCritical: false,
        allowSpeak: true,
      );
    }

    // Tier 1: Always critical
    if (_containsAnyLoose(t, _immediateInfrastructureHazards)) {
      return const SpeechDecision(
        priority: HazardPriority.critical,
        isCritical: true,
        allowSpeak: true,
      );
    }

    if (_containsAnyLoose(t, _contextualInfrastructureHazards)) {
      final near = _containsAnyLoose(t, _nearCues);
      return SpeechDecision(
        priority: near ? HazardPriority.critical : HazardPriority.awareness,
        isCritical: near,
        allowSpeak: true,
      );
    }

    // Vehicles: critical only when they are moving toward the user or
    // actually blocking/crossing the walking path. Parked/side vehicles
    // should not be escalated to critical automatically.
    if (_containsAnyLoose(t, _vehicleHazards)) {
      final vehicleCritical = _containsAnyLoose(t, _vehicleCriticalCues);
      if (vehicleCritical) {
        return const SpeechDecision(
          priority: HazardPriority.critical,
          isCritical: true,
          allowSpeak: true,
        );
      }
      return SpeechDecision(
        priority: HazardPriority.awareness,
        isCritical: false,
        allowSpeak: true,
      );
    }

    // Navigation aids: critical only with proximity cue
    if (_containsAnyLoose(t, _navigationAids)) {
      final near = _containsAnyLoose(t, _nearCues);
      return SpeechDecision(
        priority: near ? HazardPriority.critical : HazardPriority.awareness,
        isCritical: near,
        allowSpeak: true,
      );
    }

    // Surface + proximity
    if (_containsAnyLoose(t, _surfaceConditions) &&
        _containsAnyLoose(t, _nearCues)) {
      return const SpeechDecision(
        priority: HazardPriority.critical,
        isCritical: true,
        allowSpeak: true,
      );
    }

    // Directional + proximity or infrastructure
    if (_containsAnyLoose(t, _directionalCues) &&
        (_containsAnyLoose(t, _nearCues) ||
            _containsAnyLoose(t, _immediateInfrastructureHazards))) {
      return const SpeechDecision(
        priority: HazardPriority.critical,
        isCritical: true,
        allowSpeak: true,
      );
    }

    // Tier 2: Proximity-critical
    if (_containsAnyLoose(t, _movingObjects) ||
        _containsAnyLoose(t, _animalHazards)) {
      final near = _containsAnyLoose(t, _nearCues);
      return SpeechDecision(
        priority: near ? HazardPriority.critical : HazardPriority.awareness,
        isCritical: near,
        allowSpeak: true,
      );
    }

    // Tier 3: Soft hazards (people)
    final softKinds = _detectSoftHazardKinds(t);
    if (softKinds.isEmpty) {
      // Quiet mode: no actionable cue found, keep UI text but skip TTS.
      return const SpeechDecision(
        priority: HazardPriority.clear,
        isCritical: false,
        allowSpeak: true,
      );
    }

    if (recordSoftSequenceHit) _recordSoftHits(nowMs, softKinds);

    final hasSoftCriticalCue = _containsAnyLoose(t, _softCriticalCues);
    if (hasSoftCriticalCue) {
      return const SpeechDecision(
        priority: HazardPriority.critical,
        isCritical: true,
        allowSpeak: true,
      );
    }

    return SpeechDecision(
      priority: HazardPriority.awareness,
      isCritical: false,
      allowSpeak: true,
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  bool _containsAnyLoose(String t, List<String> needles) =>
      needles.any((n) => _matchesLooseNeedle(t, n));

  bool _looksLikeClearPhrase(String text) {
    final normalized = _normalizeComparisonText(text);
    return _clearPhrases.any(
      (phrase) =>
          normalized == phrase ||
          normalized.startsWith('$phrase ') ||
          normalized.endsWith(' $phrase') ||
          normalized.contains(' $phrase ') ||
          normalized.contains(phrase),
    );
  }

  bool _looksLikeLowVisibilityPhrase(String text) {
    final normalized = _normalizeComparisonText(text);
    return _lowVisibilityPhrases.any((phrase) => normalized == phrase);
  }

  bool _looksLikeSafeOpenPathContext(String text) {
    final normalized = _normalizeComparisonText(text);
    final mentionsOnlySoftHazards =
        !_containsAnyLoose(normalized, _immediateInfrastructureHazards) &&
        !_containsAnyLoose(normalized, _contextualInfrastructureHazards) &&
        !_containsAnyLoose(normalized, _vehicleHazards) &&
        !_containsAnyLoose(normalized, _animalHazards) &&
        !_containsAnyLoose(normalized, _movingObjects);
    if (!mentionsOnlySoftHazards) return false;

    final hasNoHazardCue = _noHazardPhrases.any(
      (phrase) => normalized.contains(phrase),
    );
    if (hasNoHazardCue) return true;

    return _clearPhrases.any((phrase) => normalized.contains(phrase));
  }

  String _normalizeComparisonText(String text) {
    final normalized = text
        .replaceAll(RegExp("[.!?,;:\"']"), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return normalized;
  }

  bool _matchesLooseNeedle(String t, String needle) {
    if (needle.isEmpty) return false;

    // Thai terms do not use whitespace word boundaries reliably, so keep
    // substring matching for them. English terms should match whole tokens or
    // phrases to avoid false positives like "car" in "careful".
    if (RegExp(r'[A-Za-z]').hasMatch(needle)) {
      final re = RegExp(
        r'(^|[^a-z0-9])' +
            RegExp.escape(needle.toLowerCase()) +
            r'([^a-z0-9]|$)',
      );
      return re.hasMatch(t);
    }

    return t.contains(needle);
  }

  bool _hasEnWord(String t, String w) {
    final re = RegExp(r'(^|[^a-z0-9])' + RegExp.escape(w) + r'([^a-z0-9]|$)');
    return re.hasMatch(t);
  }

  Set<String> _detectSoftHazardKinds(String t) {
    final found = <String>{};

    for (final th in _softHazardsTh) {
      if (t.contains(th)) {
        final kind = _softHazardCategoryTh[th];
        if (kind != null) found.add(kind);
      }
    }

    for (final en in _softHazardsEn) {
      if (_hasEnWord(t, en)) {
        final kind = _softHazardCategoryEn[en];
        if (kind != null) found.add(kind);
      }
    }

    return found;
  }

  void _recordSoftHits(int nowMs, Set<String> keys) {
    for (final k in keys) {
      final hits = _softHitsMs.putIfAbsent(k, () => []);
      hits.add(nowMs);
      _pruneOldHits(hits, nowMs);
    }
    _softHitsMs.removeWhere((_, hits) {
      _pruneOldHits(hits, nowMs);
      return hits.isEmpty;
    });
  }

  void _pruneOldHits(List<int> hits, int nowMs) {
    final cutoff = nowMs - _softEscalationWindow.inMilliseconds;
    while (hits.isNotEmpty && hits.first < cutoff) {
      hits.removeAt(0);
    }
  }

  String _normalizeTextKey(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}
