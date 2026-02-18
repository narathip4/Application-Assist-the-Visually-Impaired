class SpeakDecision {
  final bool shouldSpeak;
  final String text;

  SpeakDecision(this.shouldSpeak, this.text);
}

class SpeakPolicy {
  /// Cooldown สำหรับ non-critical
  final Duration cooldown;

  /// กัน critical spam แบบ hard limit (สั้นๆ)
  final Duration criticalMinInterval;
  final Duration repeatedTextWindow;

  DateTime _lastSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastCriticalAt = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, int> _lastSpokenKeyAtMs = <String, int>{};

  SpeakPolicy({
    required this.cooldown,
    this.criticalMinInterval = const Duration(milliseconds: 400),
    this.repeatedTextWindow = const Duration(milliseconds: 4500),
  });

  SpeakDecision decide({
    required String description,
    required bool isCritical,
  }) {
    final now = DateTime.now();

    // Basic cleanup
    final text = description.trim();
    if (text.isEmpty) return SpeakDecision(false, text);

    // Critical bypass cooldown, but enforce a short hard limit
    if (isCritical) {
      if (now.difference(_lastCriticalAt) < criticalMinInterval) {
        return SpeakDecision(false, text);
      }
      _lastCriticalAt = now;
      // ไม่อัปเดต _lastSpokenAt เพื่อไม่ให้ critical ไปบล็อก non-critical ต่อ
      return SpeakDecision(true, text);
    }

    final key = _normalizeKey(text);
    final nowMs = now.millisecondsSinceEpoch;
    final lastSameAt = _lastSpokenKeyAtMs[key];
    if (lastSameAt != null &&
        nowMs - lastSameAt < repeatedTextWindow.inMilliseconds) {
      return SpeakDecision(false, text);
    }

    // Non-critical cooldown gate
    if (now.difference(_lastSpokenAt) < cooldown) {
      return SpeakDecision(false, text);
    }

    _lastSpokenAt = now;
    _lastSpokenKeyAtMs[key] = nowMs;
    _pruneKeyCache(nowMs);
    return SpeakDecision(true, text);
  }

  String _normalizeKey(String text) {
    return text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  void _pruneKeyCache(int nowMs) {
    final cutoff = nowMs - (repeatedTextWindow.inMilliseconds * 3);
    _lastSpokenKeyAtMs.removeWhere((_, atMs) => atMs < cutoff);
  }
}
