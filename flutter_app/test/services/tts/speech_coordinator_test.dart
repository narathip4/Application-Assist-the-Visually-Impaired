import 'package:app/services/tts/speech_coordinator.dart';
import 'package:app/services/tts/tts_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SpeechCoordinator coordinator;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() {
    coordinator = SpeechCoordinator(tts: TtsService());
  });

  test('soft hazards stay awareness when only the path ahead is mentioned', () {
    final decision = coordinator.evaluate(
      'คนเดินเข้าไปในตรอกเปิดโล่งซึ่งมีร้านค้าอยู่สองข้างทาง และฉากก็ชัดเจนพอที่จะเห็นรายละเอียดต่างๆ เช่น เส้นทางข้างหน้า',
    );

    expect(decision.priority, HazardPriority.awareness);
    expect(decision.isCritical, isFalse);
    expect(decision.allowSpeak, isTrue);
  });

  test('soft hazards become critical when directly crossing the path', () {
    final decision = coordinator.evaluate(
      'A person is crossing in front and blocking your path.',
    );

    expect(decision.priority, HazardPriority.critical);
    expect(decision.isCritical, isTrue);
    expect(decision.allowSpeak, isTrue);
  });

  test('side curb wording with parked motorcycles stays awareness', () {
    final decision = coordinator.evaluate(
      'ตรอกแคบๆ ที่มีร้านค้าสองข้างทาง มีมอเตอร์ไซค์จอดอยู่ริมขอบทางขวา และคนเดินเท้าเดินมาทั้งสองทาง',
    );

    expect(decision.priority, HazardPriority.awareness);
    expect(decision.isCritical, isFalse);
    expect(decision.allowSpeak, isTrue);
  });

  test('curb ahead remains critical', () {
    final decision = coordinator.evaluate('มีขอบทางข้างหน้า');

    expect(decision.priority, HazardPriority.critical);
    expect(decision.isCritical, isTrue);
    expect(decision.allowSpeak, isTrue);
  });
}
