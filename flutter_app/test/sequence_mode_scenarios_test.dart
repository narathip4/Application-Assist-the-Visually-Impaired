import 'dart:async';

import 'package:app/services/tts/speak_policy.dart';
import 'package:app/services/tts/speech_coordinator.dart';
import 'package:app/services/tts/tts_service.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeTtsService extends TtsService {
  FakeTtsService({this.speakDuration = const Duration(milliseconds: 150)});

  final Duration speakDuration;
  final List<String> spokenTexts = <String>[];
  int stopCalls = 0;

  Completer<void>? _activeSpeech;

  @override
  Future<void> init() async {}

  @override
  Future<void> refreshSettings() async {}

  @override
  Future<void> speak(String text) async {
    spokenTexts.add(text);
    final completer = Completer<void>();
    _activeSpeech = completer;

    await Future.any<void>(<Future<void>>[
      completer.future,
      Future<void>.delayed(speakDuration),
    ]);

    if (identical(_activeSpeech, completer)) {
      _activeSpeech = null;
    }
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    final active = _activeSpeech;
    if (active != null && !active.isCompleted) {
      active.complete();
    }
    _activeSpeech = null;
  }

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Sequence mode policy', () {
    test('Critical bypasses cooldown gate', () {
      final policy = SpeakPolicy(cooldown: const Duration(seconds: 2));

      final first = policy.decide(description: 'car ahead', isCritical: true);
      final second = policy.decide(description: 'car ahead', isCritical: true);

      expect(first.shouldSpeak, isTrue);
      expect(second.shouldSpeak, isTrue);
    });

    test('Non-critical cooldown suppresses rapid repeats', () {
      final policy = SpeakPolicy(cooldown: const Duration(seconds: 2));

      final first = policy.decide(
        description: 'crosswalk on the left',
        isCritical: false,
      );
      final second = policy.decide(
        description: 'crosswalk on the left',
        isCritical: false,
      );

      expect(first.shouldSpeak, isTrue);
      expect(second.shouldSpeak, isFalse);
    });
  });

  group('Sequence mode scenarios', () {
    test('Input sequence: person -> person -> person near', () {
      final coordinator = SpeechCoordinator(tts: FakeTtsService());

      final step1 = coordinator.evaluate('person on the left');
      final step2 = coordinator.evaluate('person on the left');
      final step3 = coordinator.evaluate('person near and blocking path');

      expect(step1.allowSpeak, isFalse); // first soft hit can be silent
      expect(step2.allowSpeak, isTrue); // persistence in short window
      expect(step2.isCritical, isFalse);
      expect(step3.allowSpeak, isTrue); // proximity escalates immediately
      expect(step3.isCritical, isTrue);
    });

    test('Input sequence persistence resets after window', () async {
      final coordinator = SpeechCoordinator(tts: FakeTtsService());

      final first = coordinator.evaluate('person on the left');
      final second = coordinator.evaluate('person on the left');
      expect(first.allowSpeak, isFalse);
      expect(second.allowSpeak, isTrue);

      // Soft sequence window is 2.5s; after this window persistence should reset.
      await Future<void>.delayed(const Duration(milliseconds: 2600));
      final afterWindow = coordinator.evaluate('person on the left');
      expect(afterWindow.allowSpeak, isFalse);
    });

    test('Burst test (2s): non-critical does not spam', () async {
      final tts = FakeTtsService(speakDuration: const Duration(milliseconds: 50));
      final coordinator = SpeechCoordinator(tts: tts);
      final policy = SpeakPolicy(cooldown: const Duration(seconds: 2));

      for (var i = 0; i < 10; i++) {
        final message = 'crosswalk on the left';
        final decision = coordinator.evaluate(message);
        if (!decision.allowSpeak) continue;
        final speakDecision = policy.decide(
          description: message,
          isCritical: decision.isCritical,
        );
        if (!speakDecision.shouldSpeak) continue;
        unawaited(
          coordinator.speak(
            speakDecision.text,
            isCritical: decision.isCritical,
            ttsEnabled: true,
          ),
        );
      }

      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(tts.spokenTexts.length, 1);
    });

    test('Interrupt test: critical cuts current speech', () async {
      final tts = FakeTtsService(speakDuration: const Duration(milliseconds: 300));
      final coordinator = SpeechCoordinator(tts: tts);

      unawaited(
        coordinator.speak(
          'sidewalk on the right',
          isCritical: false,
          ttsEnabled: true,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await coordinator.speak(
        'car ahead',
        isCritical: true,
        ttsEnabled: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(tts.stopCalls, greaterThanOrEqualTo(1));
      expect(tts.spokenTexts.last, 'car ahead');
    });

    test('No queue: non-critical while speaking is dropped', () async {
      final tts = FakeTtsService(speakDuration: const Duration(milliseconds: 300));
      final coordinator = SpeechCoordinator(tts: tts);

      unawaited(
        coordinator.speak(
          'sidewalk on the right',
          isCritical: false,
          ttsEnabled: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await coordinator.speak(
        'tactile paving on the left',
        isCritical: false,
        ttsEnabled: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(tts.spokenTexts.length, 1);
      expect(tts.spokenTexts.first, 'sidewalk on the right');
      expect(tts.stopCalls, 0);
    });

    test('Critical duplicate is suppressed in short window', () async {
      final tts = FakeTtsService(speakDuration: const Duration(milliseconds: 250));
      final coordinator = SpeechCoordinator(tts: tts);

      unawaited(
        coordinator.speak(
          'car ahead',
          isCritical: true,
          ttsEnabled: true,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 30));
      await coordinator.speak(
        'car ahead',
        isCritical: true,
        ttsEnabled: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 280));

      expect(tts.spokenTexts.length, 1);
    });

    test('Persistence test: 1 hit silent, 2 hits in window speak', () {
      final coordinator = SpeechCoordinator(tts: FakeTtsService());

      final first = coordinator.evaluate('person on the left');
      final second = coordinator.evaluate('person on the left');

      expect(first.allowSpeak, isFalse);
      expect(second.allowSpeak, isTrue);
      expect(second.isCritical, isFalse);
    });

    test('Proximity test: ahead/near/blocking becomes critical', () {
      final coordinator = SpeechCoordinator(tts: FakeTtsService());
      final decision = coordinator.evaluate('person ahead blocking path');

      expect(decision.allowSpeak, isTrue);
      expect(decision.isCritical, isTrue);
    });

    test('Proximity with soft hazard escalates immediately', () {
      final coordinator = SpeechCoordinator(tts: FakeTtsService());
      final decision = coordinator.evaluate('person near me');

      expect(decision.allowSpeak, isTrue);
      expect(decision.isCritical, isTrue);
    });
  });
}
