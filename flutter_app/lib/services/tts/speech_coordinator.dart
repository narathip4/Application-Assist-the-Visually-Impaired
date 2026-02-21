import 'package:flutter/foundation.dart';
import 'tts_service.dart';

class SpeechDecision {
  final bool isCritical;
  final bool allowSpeak;
  const SpeechDecision({required this.isCritical, required this.allowSpeak});
}

class SequenceDebugState {
  final String message;
  final int evaluatedAtMs;
  final bool hasNearCue;
  final bool persistentSoftHazard;
  final List<String> softKinds;
  final Map<String, int> softHitCounts;
  final bool isCritical;
  final bool allowSpeak;

  const SequenceDebugState({
    this.message = '',
    this.evaluatedAtMs = 0,
    this.hasNearCue = false,
    this.persistentSoftHazard = false,
    this.softKinds = const <String>[],
    this.softHitCounts = const <String, int>{},
    this.isCritical = false,
    this.allowSpeak = false,
  });
}

class SpeechCoordinator {
  final TtsService _tts;

  bool _isSpeaking = false;
  bool _activeIsCritical = false;
  String? _activeTextKey;
  String? _lastCriticalTextKey;
  int _lastCriticalSpokenAtMs = 0;

  static const int _criticalRepeatSuppressMs = 1200;
  static const Duration _softEscalationWindow = Duration(milliseconds: 3800);
  static const int _softEscalationHits = 2;
  static const String _softKindPerson = 'person';

  final Map<String, List<int>> _softHitsMs = {};
  SequenceDebugState _lastDebugState = const SequenceDebugState();

  SpeechCoordinator({required TtsService tts}) : _tts = tts;

  // Hazard keyword lists

  static const List<String> _infrastructureHazards = [
    'บันได',
    'ขั้นบันได',
    'บันไดเลื่อน',
    'หลุม',
    'หลุมก่อสร้าง',
    'ฝาท่อ',
    'ลื่น',
    'ขอบ',
    'ขอบทาง',
    'ผนัง',
    'กำแพง',
    'เสา',
    'เสาไฟฟ้า',
    'ประตู',
    'ประตูอัตโนมัติ',
    'กระจก',
    'สิ่งกีดขวาง',
    'กีดขวาง',
    'ต้นไม้',
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
    'edge',
    'curb',
    'wall',
    'pole',
    'power pole',
    'door',
    'automatic door',
    'glass',
    'obstacle',
    'tree',
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

  static const List<String> _vehicleHazards = [
    'รถยนต์',
    'รถบรรทุก',
    'รถโดยสาร',
    'มอเตอร์ไซค์',
    'รถจักรยานยนต์',
    'จักรยาน',
    'car',
    'truck',
    'bus',
    'motorcycle',
    'motorbike',
    'vehicle',
    'bike',
    'bicycle',
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
    'หน้า',
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

  // Public API

  SpeechDecision evaluate(String message) =>
      _evaluateInternal(message, recordSoftSequenceHit: true);

  bool isCriticalMessage(String message) =>
      _evaluateInternal(message, recordSoftSequenceHit: false).isCritical;

  bool hasNavigationAid(String message) =>
      _containsAny(message, _navigationAids);
  bool hasDirectionalInfo(String message) =>
      _containsAny(message, _directionalCues);
  bool hasNearProximity(String message) => _containsAny(message, _nearCues);
  bool hasVehicleHazard(String message) =>
      _containsAny(message, _vehicleHazards);
  bool hasInfrastructureHazard(String message) =>
      _containsAny(message, _infrastructureHazards);
  bool hasAnimalHazard(String message) => _containsAny(message, _animalHazards);
  bool hasMovingObject(String message) => _containsAny(message, _movingObjects);
  SequenceDebugState get debugState => _lastDebugState;

  /// Returns 0 = suppressed, 1 = normal, 2 = high, 3 = critical
  int getPriorityLevel(String message) {
    final decision = _evaluateInternal(message, recordSoftSequenceHit: false);
    if (!decision.allowSpeak) return 0;
    if (!decision.isCritical) return 1;

    final t = message.toLowerCase();

    if (_containsAnyLoose(t, _infrastructureHazards) ||
        _containsAnyLoose(t, _vehicleHazards)) {
      return 3;
    }

    return 2;
  }

  Future<void> speak(
    String text, {
    required bool isCritical,
    required bool ttsEnabled,
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

      if (_isSpeaking) {
        await _tts.stop();
        _isSpeaking = false;
      }
    }

    if (_isSpeaking && !isCritical) return;

    _isSpeaking = true;
    _activeIsCritical = isCritical;
    _activeTextKey = normalized;

    if (isCritical) {
      _lastCriticalTextKey = normalized;
      _lastCriticalSpokenAtMs = nowMs;
    }

    try {
      await _tts.speak(text);
    } catch (e) {
      debugPrint('[SpeechCoordinator] TTS error: $e');
    } finally {
      _isSpeaking = false;
      _activeIsCritical = false;
      _activeTextKey = null;
    }
  }

  Future<void> stop() async {
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

    // Tier 1: Always critical
    if (_containsAnyLoose(t, _infrastructureHazards) ||
        _containsAnyLoose(t, _vehicleHazards)) {
      return _withDebugState(
        message: message,
        nowMs: nowMs,
        hasNearCue: _containsAnyLoose(t, _nearCues),
        softKinds: const <String>{},
        persistent: false,
        decision: const SpeechDecision(isCritical: true, allowSpeak: true),
      );
    }

    // Navigation aids: critical only with proximity cue
    if (_containsAnyLoose(t, _navigationAids)) {
      final near = _containsAnyLoose(t, _nearCues);
      return _withDebugState(
        message: message,
        nowMs: nowMs,
        hasNearCue: near,
        softKinds: const <String>{},
        persistent: false,
        decision: SpeechDecision(isCritical: near, allowSpeak: true),
      );
    }

    // Surface + proximity
    if (_containsAnyLoose(t, _surfaceConditions) &&
        _containsAnyLoose(t, _nearCues)) {
      return _withDebugState(
        message: message,
        nowMs: nowMs,
        hasNearCue: true,
        softKinds: const <String>{},
        persistent: false,
        decision: const SpeechDecision(isCritical: true, allowSpeak: true),
      );
    }

    // Directional + proximity or infrastructure
    if (_containsAnyLoose(t, _directionalCues) &&
        (_containsAnyLoose(t, _nearCues) ||
            _containsAnyLoose(t, _infrastructureHazards))) {
      return _withDebugState(
        message: message,
        nowMs: nowMs,
        hasNearCue: _containsAnyLoose(t, _nearCues),
        softKinds: const <String>{},
        persistent: false,
        decision: const SpeechDecision(isCritical: true, allowSpeak: true),
      );
    }

    // Tier 2: Proximity-critical
    if (_containsAnyLoose(t, _movingObjects) ||
        _containsAnyLoose(t, _animalHazards)) {
      final near = _containsAnyLoose(t, _nearCues);
      return _withDebugState(
        message: message,
        nowMs: nowMs,
        hasNearCue: near,
        softKinds: const <String>{},
        persistent: false,
        decision: SpeechDecision(isCritical: near, allowSpeak: true),
      );
    }

    // Tier 3: Soft hazards (people)
    final softKinds = _detectSoftHazardKinds(t);
    if (softKinds.isEmpty) {
      return _withDebugState(
        message: message,
        nowMs: nowMs,
        hasNearCue: _containsAnyLoose(t, _nearCues),
        softKinds: const <String>{},
        persistent: false,
        decision: const SpeechDecision(isCritical: false, allowSpeak: true),
      );
    }

    if (recordSoftSequenceHit) _recordSoftHits(nowMs, softKinds);

    final hasNearCue = _containsAnyLoose(t, _nearCues);
    if (hasNearCue) {
      return _withDebugState(
        message: message,
        nowMs: nowMs,
        hasNearCue: true,
        softKinds: softKinds,
        persistent: false,
        decision: const SpeechDecision(isCritical: true, allowSpeak: true),
      );
    }

    final persistent = _isPersistent(
      nowMs,
      softKinds,
      prune: recordSoftSequenceHit,
    );
    return _withDebugState(
      message: message,
      nowMs: nowMs,
      hasNearCue: hasNearCue,
      softKinds: softKinds,
      persistent: persistent,
      decision: SpeechDecision(isCritical: false, allowSpeak: persistent),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  bool _containsAny(String message, List<String> needles) =>
      _containsAnyLoose(message.toLowerCase(), needles);

  bool _containsAnyLoose(String t, List<String> needles) =>
      needles.any((n) => t.contains(n));

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

  bool _isPersistent(int nowMs, Set<String> keys, {required bool prune}) {
    for (final k in keys) {
      final hits = _softHitsMs[k];
      if (hits == null) continue;

      if (prune) {
        _pruneOldHits(hits, nowMs);
        if (hits.length >= _softEscalationHits) return true;
      } else {
        final cutoff = nowMs - _softEscalationWindow.inMilliseconds;
        if (hits.where((ts) => ts >= cutoff).length >= _softEscalationHits)
          return true;
      }
    }
    return false;
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

  SpeechDecision _withDebugState({
    required String message,
    required int nowMs,
    required bool hasNearCue,
    required Set<String> softKinds,
    required bool persistent,
    required SpeechDecision decision,
  }) {
    final hitCounts = <String, int>{};
    for (final kind in softKinds) {
      final hits = _softHitsMs[kind];
      if (hits == null) {
        hitCounts[kind] = 0;
        continue;
      }
      var recent = 0;
      final cutoff = nowMs - _softEscalationWindow.inMilliseconds;
      for (final ts in hits) {
        if (ts >= cutoff) recent++;
      }
      hitCounts[kind] = recent;
    }

    _lastDebugState = SequenceDebugState(
      message: message,
      evaluatedAtMs: nowMs,
      hasNearCue: hasNearCue,
      persistentSoftHazard: persistent,
      softKinds: softKinds.toList()..sort(),
      softHitCounts: hitCounts,
      isCritical: decision.isCritical,
      allowSpeak: decision.allowSpeak,
    );

    return decision;
  }
}
