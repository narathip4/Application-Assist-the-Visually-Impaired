class SpeakDecision {
  final bool shouldSpeak;
  final bool interrupt;
  final String text;

  const SpeakDecision({
    required this.shouldSpeak,
    required this.interrupt,
    required this.text,
  });

  static const none =
      SpeakDecision(shouldSpeak: false, interrupt: false, text: '');
}

class SpeakPolicy {
  String? _lastSpoken;
  DateTime _lastSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);

  final Duration cooldown;

  SpeakPolicy({this.cooldown = const Duration(seconds: 2)});

  /// Decide whether to speak a plain image description
  SpeakDecision decide({
    required String description,
  }) {
    final text = description.trim();
    if (text.isEmpty) return SpeakDecision.none;

    final now = DateTime.now();

    // 1) ไม่พูดซ้ำข้อความเดิม
    if (_lastSpoken != null && text == _lastSpoken) {
      return SpeakDecision.none;
    }

    // 2) เคารพ cooldown (กันพูดรัว)
    if (now.difference(_lastSpokenAt) < cooldown) {
      return SpeakDecision.none;
    }

    // 3) ผ่านเงื่อนไข -> พูด
    _lastSpoken = text;
    _lastSpokenAt = now;

    return SpeakDecision(
      shouldSpeak: true,
      interrupt: false, // ไม่มี urgent mode ตอนนี้
      text: text,
    );
  }

  void reset() {
    _lastSpoken = null;
    _lastSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);
  }
}
