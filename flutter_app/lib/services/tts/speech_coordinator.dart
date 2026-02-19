import 'package:flutter/foundation.dart';
import 'tts_service.dart';

class SpeechDecision {
  final bool isCritical;
  final bool allowSpeak;
  const SpeechDecision({required this.isCritical, required this.allowSpeak});
}

class SpeechCoordinator {
  final TtsService _tts;

  bool _isSpeaking = false;
  bool _activeIsCritical = false;
  String? _activeTextKey;
  String? _lastCriticalTextKey;
  int _lastCriticalSpokenAtMs = 0;

  // Suppress repeated critical spam with the same message in a short window.
  static const int _criticalRepeatSuppressMs = 1200;

  // --- Soft-hazard sequence tracking (metadata only; no frame queue) ---
  static const Duration _softEscalationWindow = Duration(milliseconds: 2500);
  static const int _softEscalationHits = 2;

  final Map<String, List<int>> _softHitsMs = <String, List<int>>{};

  static const String _softKindPerson = 'person';

  SpeechCoordinator({required TtsService tts}) : _tts = tts;

  // ============================================================================
  // HAZARD CLASSIFICATION - SAFETY-CRITICAL FOR VISUALLY IMPAIRED USERS
  // ============================================================================
  //
  // Classification based on real-world injury risk analysis:
  // - Can it kill or cause severe injury to a blind pedestrian?
  // - How fast does danger escalate?
  // - Can user react in time with audio warning only?
  //
  // ============================================================================

  // ----------------------------------------------------------------------------
  // TIER 1: ALWAYS CRITICAL - Immediate danger, no persistence needed
  // Fatal or severe injury risk, requires instant warning
  // ----------------------------------------------------------------------------

  /// Physical infrastructure hazards
  /// Static obstacles causing collision, fall, or severe injury
  static const List<String> _infrastructureHazards = <String>[
    // อันตรายโครงสร้าง (TH)
    'บันได', // stairs - fall from height
    'ขั้นบันได', // step
    'บันไดเลื่อน', // escalator - moving machinery
    'หลุม', // hole - fall risk
    'หลุมก่อสร้าง', // construction pit - deep fall (fatal)
    'ฝาท่อ', // manhole - underground fall (fatal)
    'ลื่น', // slippery - fall + head injury
    'ขอบ', // edge - platform/curb fall
    'ขอบทาง', // curb edge
    'ผนัง', // wall - face collision
    'กำแพง', // wall
    'เสา', // pole - head collision
    'เสาไฟฟ้า', // power pole
    'ประตู', // door - collision/trap
    'ประตูอัตโนมัติ', // automatic door - moving trap
    'กระจก', // glass - invisible (facial cuts)
    'สิ่งกีดขวาง', // obstacle (generic)
    'กีดขวาง', // blocking
    'ต้นไม้', // tree - collision (low branches)
    'ป้ายจราจร', // traffic sign - metal pole
    'ทางลาด', // ramp - elevation change warning
    'ท่อระบายน้ำ', // drain - gap/foot trap
    'โซ่กั้น', // chain barrier - neck height (strangle)
    'เชือกกั้น', // rope barrier - trip/strangle
    'กรวยจราจร', // traffic cone - trip + construction area
    'นั่งร้าน', // street vendor stall
    'แผงลอย', // food stall - hot food, obstacles
    // Infrastructure hazards (EN)
    'stairs', // fall from height
    'stair',
    'step',
    'escalator', // moving machinery
    'hole', // fall risk
    'construction pit', // deep fall (fatal)
    'manhole', // underground fall (fatal)
    'slippery', // fall + head injury
    'edge', // platform/curb fall
    'curb', // trip, ankle injury
    'wall', // face collision
    'pole', // head collision
    'power pole',
    'door', // collision/trap
    'automatic door', // moving trap/crush
    'glass', // invisible barrier (cuts)
    'obstacle', // generic collision
    'tree', // collision (branches)
    'sign', // traffic sign pole
    'traffic sign',
    'ramp', // elevation change
    'drain', // gap/foot trap
    'chain barrier', // strangle risk
    'rope barrier', // trip/strangle
    'traffic cone', // trip + construction
    'street vendor', // obstacle + hot food
    'food stall', // hot food, fire risk
  ];

  /// ALL vehicles - motorized AND human-powered
  /// CRITICAL SAFETY: Any moving vehicle is severe injury/fatal risk to blind users
  ///
  /// Why bikes are Tier 1 (not soft):
  /// - Speed: 15-30 km/h impact = broken bones, head injury
  /// - Weight: 10-15 kg bike + 60-80 kg rider = serious collision
  /// - Silent approach: Blind user cannot hear bicycle
  /// - Reaction time: Cyclist may not see/brake in time
  /// - Real injury: Knocked down blind person = head trauma, fractures
  static const List<String> _vehicleHazards = <String>[
    // ยานพาหนะ - มอเตอร์ (TH)
    'รถยนต์', // car
    'รถบรรทุก', // truck
    'รถโดยสาร', // bus
    'มอเตอร์ไซค์', // motorcycle
    'รถจักรยานยนต์', // motorcycle
    // ยานพาหนะ - พลังคน (TH) - SERIOUS INJURY RISK
    'จักรยาน', // bicycle - 20+ km/h collision = broken bones
    // Motorized vehicles (EN)
    'car', // fatal risk
    'truck', // fatal risk
    'bus', // fatal risk
    'motorcycle', // fatal risk
    'motorbike', // fatal risk
    'vehicle', // generic vehicle
    // Human-powered vehicles (EN) - SERIOUS INJURY RISK
    'bike', // 20+ km/h = broken bones, head injury
    'bicycle', // same as bike
  ];

  // ----------------------------------------------------------------------------
  // TIER 2: PROXIMITY-CRITICAL - Critical when approaching/near
  // Moderate to serious injury risk, but distance matters
  // ----------------------------------------------------------------------------

  /// Animals - unpredictable behavior, bite/attack risk when near
  /// Far away: not dangerous | Approaching: critical
  static const List<String> _animalHazards = <String>[
    // สัตว์ (TH)
    'สุนัข', // dog - bite/attack risk when near
    'แมว', // cat - scratch (low risk but unpredictable)
    'สัตว์', // animal (generic) - unknown risk
    // Animals (EN)
    'dog', // bite/attack when approaching
    'cat', // scratch risk (low)
    'animal', // unknown animal type
  ];

  /// Moving objects/carts - injury risk depends on proximity and speed
  /// Generic carts, hand carts, shopping carts
  /// Note: Food stalls already in Tier 1 infrastructure
  static const List<String> _movingObjects = <String>[
    // รถเข็น (TH) - generic cart (NOT wheelchair)
    'รถเข็น', // cart - could be heavy food cart or shopping cart
    // Carts (EN)
    'cart', // generic cart - medium injury risk
  ];

  // ----------------------------------------------------------------------------
  // TIER 3: SOFT HAZARDS - Need persistence OR proximity to escalate
  // Low injury risk, common in environment, spam prevention needed
  // ----------------------------------------------------------------------------

  /// Soft hazards (TH) - low injury risk
  static const List<String> _softHazardsTh = <String>[
    'คน', // person - walking collision = minor bump
  ];

  /// Soft hazards (EN) - low injury risk
  static const List<String> _softHazardsEn = <String>[
    'person', // walking collision = minor
    'pedestrian', // same as person
    'wheelchair', // slow, controlled, low injury (user-operated)
  ];

  /// Soft hazard categories for tracking persistence
  static const Map<String, String> _softHazardCategoryTh = <String, String>{
    'คน': _softKindPerson,
  };

  static const Map<String, String> _softHazardCategoryEn = <String, String>{
    'person': _softKindPerson,
    'pedestrian': _softKindPerson,
    'wheelchair': _softKindPerson, // Treat like person for persistence tracking
  };

  // ----------------------------------------------------------------------------
  // NAVIGATION & CONTEXT KEYWORDS
  // ----------------------------------------------------------------------------

  /// Navigation aids - helpful for orientation, not immediate hazards
  /// Only critical when combined with proximity cues
  static const List<String> _navigationAids = <String>[
    // ทางนำทาง (TH)
    'ทางม้าลาย', // crosswalk - WHERE to cross safely
    'ม้าลาย', // zebra crossing
    'ทางข้าม', // pedestrian crossing
    'ไฟจราจร', // traffic light
    'สัญญาณไฟ', // traffic signal
    'สัญญาณเสียง', // audio signal
    'ป้ายรถเมล์', // bus stop
    'ป้ายรถ', // bus stop sign
    'ทางลาดผู้พิการ', // wheelchair ramp (accessible)
    'ราวจับ', // handrail - helpful feature
    'แผ่นนูน', // tactile paving
    'จุดนูน', // tactile dots
    'แนวกระเบื้องนูน', // tactile strips
    'เส้นนำทาง', // guide path
    'ทางเท้า', // sidewalk - WHERE to walk
    // Navigation aids (EN)
    'crosswalk', // crossing location
    'zebra crossing',
    'pedestrian crossing',
    'traffic light', // signal location
    'signal',
    'audio signal', // accessible signal
    'bus stop', // waiting location
    'handrail', // support feature
    'tactile paving', // accessible feature
    'tactile strip',
    'guide path', // navigation feature
    'sidewalk', // safe walking area
    'pavement', // walkway
  ];

  /// Directional cues - spatial information
  static const List<String> _directionalCues = <String>[
    // ทิศทาง (TH)
    'ซ้าย', // left
    'ขวา', // right
    'หน้า', // front
    'หลัง', // behind/back
    'ซ้ายมือ', // left hand
    'ขวามือ', // right hand
    'ด้านซ้าย', // left side
    'ด้านขวา', // right side
    'เลี้ยวซ้าย', // turn left
    'เลี้ยวขวา', // turn right
    'ตรงไป', // straight/go forward
    // Directional (EN)
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

  /// Surface conditions - ground/path status
  static const List<String> _surfaceConditions = <String>[
    // พื้นผิว (TH)
    'เปียก', // wet - slip risk
    'น้ำขัง', // standing water
    'ลื่น', // slippery (also in infrastructure)
    'ขรุขระ', // rough surface
    'ไม่เรียบ', // uneven
    'หลุมบ่อ', // pothole
    'หิน', // gravel/rocks
    'ทราย', // sand
    'โคลน', // mud
    'หญ้า', // grass
    'ปูน', // concrete
    'กระเบื้อง', // tiles
    // Surface (EN)
    'wet', // slip risk
    'water', // standing water
    'slippery', // slip risk
    'rough', // uneven surface
    'uneven', // trip risk
    'pothole', // hole in ground
    'gravel', // loose stones
    'sand', // unstable surface
    'mud', // slippery + unstable
    'grass', // uneven + wet risk
    'concrete', // surface type
    'tiles', // surface type
  ];

  /// Near proximity cues - indicate immediate/approaching threat
  /// These words mean danger is CLOSE or GETTING CLOSER
  static const List<String> _nearCues = <String>[
    // ความใกล้ - อันตราย (TH)
    'ข้างหน้า', // in front of
    'ตรงหน้า', // straight ahead (immediate)
    'ด้านหน้า', // front area
    'ใกล้', // near/close
    'ใกล้มาก', // very close (urgent!)
    'เข้าใกล้', // approaching (moving toward)
    'กำลังเข้าใกล้', // currently approaching
    'ตัดหน้า', // cutting in front
    'ขวางทาง', // blocking path
    'ขวางหน้า', // blocking front
    'ชิด', // very close/tight
    'ติด', // touching/adjacent
    // Proximity - danger (EN)
    'in front', // immediate ahead
    'ahead', // in path forward
    'near', // close by
    'close', // nearby
    'very close', // urgent proximity
    'approaching', // moving toward user
    'in your path', // direct collision course
    'crossing', // intersecting path
    'blocking', // obstructing
    'nearby', // close area
  ];

  // ============================================================================
  // EVALUATION LOGIC
  // ============================================================================

  /// One-stop evaluation with safety-first hazard classification
  SpeechDecision evaluate(String message) {
    return _evaluateInternal(message, recordSoftSequenceHit: true);
  }

  SpeechDecision _evaluateInternal(
    String message, {
    required bool recordSoftSequenceHit,
  }) {
    final t = message.toLowerCase();
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // -------------------------------------------------------------------------
    // TIER 1: ALWAYS CRITICAL - Immediate severe injury/fatal danger
    // -------------------------------------------------------------------------

    // Infrastructure hazards (stairs, holes, walls, etc.)
    if (_containsAnyLoose(t, _infrastructureHazards)) {
      return const SpeechDecision(isCritical: true, allowSpeak: true);
    }

    // ALL vehicles (motorized + bikes) - ALWAYS critical
    // SAFETY-CRITICAL: Vehicles cause fatal/serious injury to blind users
    // This includes bicycles at 20+ km/h - same injury risk as motorcycles
    if (_containsAnyLoose(t, _vehicleHazards)) {
      return const SpeechDecision(isCritical: true, allowSpeak: true);
    }

    // -------------------------------------------------------------------------
    // Navigation aids - informational unless combined with proximity
    // -------------------------------------------------------------------------

    if (_containsAnyLoose(t, _navigationAids)) {
      final hasNearCue = _containsAnyLoose(t, _nearCues);
      return SpeechDecision(
        isCritical:
            hasNearCue, // "crosswalk ahead" = critical, "crosswalk" = info
        allowSpeak: true,
      );
    }

    // -------------------------------------------------------------------------
    // Surface + proximity combinations
    // Wet/slippery surfaces are critical when user is near them
    // -------------------------------------------------------------------------

    if (_containsAnyLoose(t, _surfaceConditions) &&
        _containsAnyLoose(t, _nearCues)) {
      return const SpeechDecision(isCritical: true, allowSpeak: true);
    }

    // Directional warnings with proximity or hazards
    if (_containsAnyLoose(t, _directionalCues) &&
        (_containsAnyLoose(t, _nearCues) ||
            _containsAnyLoose(t, _infrastructureHazards))) {
      return const SpeechDecision(isCritical: true, allowSpeak: true);
    }

    // -------------------------------------------------------------------------
    // TIER 2: PROXIMITY-CRITICAL - Moderate injury risk when near
    // -------------------------------------------------------------------------

    // Moving objects (carts) - critical when near
    // Generic carts could be heavy food carts (serious injury) or shopping carts
    if (_containsAnyLoose(t, _movingObjects)) {
      final hasNearCue = _containsAnyLoose(t, _nearCues);
      return SpeechDecision(
        isCritical: hasNearCue, // "cart approaching" = critical, "cart" = info
        allowSpeak: true,
      );
    }

    // Animals - bite/attack risk when near
    if (_containsAnyLoose(t, _animalHazards)) {
      final hasNearCue = _containsAnyLoose(t, _nearCues);
      return SpeechDecision(
        isCritical: hasNearCue, // "dog approaching" = critical, "dog" = info
        allowSpeak: true,
      );
    }

    // -------------------------------------------------------------------------
    // TIER 3: Soft hazards (people, wheelchair) - persistence + proximity logic
    // Low injury risk, common in environment, spam prevention needed
    // -------------------------------------------------------------------------

    final softKinds = _detectSoftHazardKinds(t);
    if (softKinds.isEmpty) {
      // Not a hazard -> allow speak (SpeakPolicy controls cooldown)
      return const SpeechDecision(isCritical: false, allowSpeak: true);
    }

    final hasNearCues = _containsAnyLoose(t, _nearCues);

    if (recordSoftSequenceHit) {
      // Record hits only in speech path to avoid UI-driven double counting
      _recordSoftHits(nowMs, softKinds);
    }

    // Soft hazard with proximity -> critical
    if (hasNearCues) {
      return const SpeechDecision(isCritical: true, allowSpeak: true);
    }

    final persistent = _isPersistent(
      nowMs,
      softKinds,
      prune: recordSoftSequenceHit,
    );

    // Persistent soft hazards -> allow speak but non-critical
    // (Let SpeakPolicy cooldown manage frequency in crowded areas)
    if (persistent) {
      return const SpeechDecision(isCritical: false, allowSpeak: true);
    }

    // Not persistent, no proximity -> suppress to prevent spam
    return const SpeechDecision(isCritical: false, allowSpeak: false);
  }

  // ============================================================================
  // HELPER METHODS
  // ============================================================================

  bool _containsAnyLoose(String t, List<String> needles) {
    for (final n in needles) {
      if (t.contains(n)) return true;
    }
    return false;
  }

  bool _containsAnyInMessage(String message, List<String> needles) {
    return _containsAnyLoose(message.toLowerCase(), needles);
  }

  // English token match (word boundary-ish)
  // Safer than contains('car') which would match 'scar' or 'cart'
  bool _hasEnWord(String t, String w) {
    final re = RegExp(r'(^|[^a-z0-9])' + RegExp.escape(w) + r'([^a-z0-9]|$)');
    return re.hasMatch(t);
  }

  Set<String> _detectSoftHazardKinds(String t) {
    final found = <String>{};

    // Thai: contains is acceptable (no whitespace boundaries needed)
    for (final th in _softHazardsTh) {
      if (t.contains(th)) {
        final kind = _softHazardCategoryTh[th];
        if (kind != null) found.add(kind);
      }
    }

    // English: word-boundary-ish matching
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
        continue;
      }

      var recentCount = 0;
      final cutoff = nowMs - _softEscalationWindow.inMilliseconds;
      for (final ts in hits) {
        if (ts >= cutoff) recentCount++;
      }
      if (recentCount >= _softEscalationHits) return true;
    }
    return false;
  }

  void _recordSoftHits(int nowMs, Set<String> keys) {
    for (final k in keys) {
      final hits = _softHitsMs.putIfAbsent(k, () => <int>[]);
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

  /// Speak with priority & interrupt handling.
  /// Enhanced for blind users: faster response, clearer priority
  Future<void> speak(
    String text, {
    required bool isCritical,
    required bool ttsEnabled,
  }) async {
    if (text.trim().isEmpty) return;
    if (!ttsEnabled) return;

    final normalized = _normalizeTextKey(text);
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // Critical should interrupt current speech immediately.
    if (isCritical) {
      final repeatedCritical =
          _lastCriticalTextKey == normalized &&
          nowMs - _lastCriticalSpokenAtMs < _criticalRepeatSuppressMs;
      if (repeatedCritical) return;

      final sameAsActiveCritical =
          _isSpeaking && _activeIsCritical && _activeTextKey == normalized;
      if (sameAsActiveCritical) return;

      if (_isSpeaking) {
        await _tts.stop();
        _isSpeaking = false;
      }
    }

    // Drop non-critical if already speaking
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

  String _normalizeTextKey(String text) {
    return text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  bool isCriticalMessage(String message) {
    return _evaluateInternal(message, recordSoftSequenceHit: false).isCritical;
  }

  /// Helper method to check if message contains navigation aid
  bool hasNavigationAid(String message) => _containsAnyInMessage(
    message,
    _navigationAids,
  );

  /// Helper method to check if message contains directional info
  bool hasDirectionalInfo(String message) => _containsAnyInMessage(
    message,
    _directionalCues,
  );

  /// Helper method to check if message has near proximity cues
  bool hasNearProximity(String message) => _containsAnyInMessage(
    message,
    _nearCues,
  );

  /// Helper method to check if message contains vehicle hazard (includes bikes)
  bool hasVehicleHazard(String message) => _containsAnyInMessage(
    message,
    _vehicleHazards,
  );

  /// Helper method to check if message contains infrastructure hazard
  bool hasInfrastructureHazard(String message) => _containsAnyInMessage(
    message,
    _infrastructureHazards,
  );

  /// Helper method to check if message contains animal
  bool hasAnimalHazard(String message) => _containsAnyInMessage(
    message,
    _animalHazards,
  );

  /// Helper method to check if message contains moving object (cart)
  bool hasMovingObject(String message) => _containsAnyInMessage(
    message,
    _movingObjects,
  );

  /// Helper method to get priority level (for UI indication)
  /// 0 = Suppressed, 1 = Normal, 2 = High, 3 = Critical
  int getPriorityLevel(String message) {
    final decision = _evaluateInternal(message, recordSoftSequenceHit: false);
    if (!decision.allowSpeak) return 0; // Suppressed

    if (decision.isCritical) {
      final t = message.toLowerCase();

      // Level 3: Infrastructure + ALL Vehicles (includes bikes) = HIGHEST
      // Fatal or severe injury risk
      if (_containsAnyLoose(t, _infrastructureHazards) ||
          _containsAnyLoose(t, _vehicleHazards)) {
        return 3; // Highest - immediate danger
      }

      // Level 2: Navigation aids + proximity, Animals/Carts near, Soft + proximity
      // Moderate injury risk or actionable navigation
      if ((_containsAnyLoose(t, _navigationAids) &&
              _containsAnyLoose(t, _nearCues)) ||
          (_containsAnyLoose(t, _animalHazards) &&
              _containsAnyLoose(t, _nearCues)) ||
          (_containsAnyLoose(t, _movingObjects) &&
              _containsAnyLoose(t, _nearCues))) {
        return 2; // High
      }

      // Soft hazards with proximity
      return 2; // Medium-high
    }

    return 1; // Normal (non-critical allowed)
  }
}
