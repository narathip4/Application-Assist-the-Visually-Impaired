class SpeakDecision {
  final bool shouldSpeak;
  final String text;

  SpeakDecision(this.shouldSpeak, this.text);
}

class SpeakPolicy {
  final Duration cooldown;
  DateTime _lastSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);

  SpeakPolicy({required this.cooldown});

  SpeakDecision decide({required String description}) {
    final now = DateTime.now();

    // Basic cleanup
    final text = description.trim();
    if (text.isEmpty) return SpeakDecision(false, text);

    // Cooldown gate (for non-critical)
    if (now.difference(_lastSpokenAt) < cooldown) {
      return SpeakDecision(false, text);
    }

    _lastSpokenAt = now;
    return SpeakDecision(true, text);
  }
}
