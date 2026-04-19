import 'package:app/services/vlm/fast_vlm_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FastVlmService service;

  setUp(() {
    service = FastVlmService(
      'https://example.com',
      timeout: const Duration(seconds: 1),
    );
  });

  test('keeps the exact clear-path fallback phrase', () {
    expect(
      service.sanitizeForTest('The path ahead is clear.'),
      'The path ahead is clear.',
    );
  });

  test('does not collapse descriptive clear scenes with landmarks', () {
    expect(
      service.sanitizeForTest(
        'The path ahead is clear with bushes on the left and stairs on the right.',
      ),
      'The path ahead is clear with bushes on the left and stairs on the right.',
    );
  });

  test('keeps the exact unclear fallback phrase', () {
    expect(
      service.sanitizeForTest('Scene unclear, cannot confirm what is ahead.'),
      'Scene unclear, cannot confirm what is ahead.',
    );
  });

  test('does not collapse visible dim scenes into too-dark fallback', () {
    expect(
      service.sanitizeForTest(
        'The image shows a computer keyboard with an open laptop screen '
        'displaying what appears to be stock market information, and the '
        'scene is dimly lit.',
      ),
      'A computer keyboard with an open laptop screen displaying what '
      'appears to be stock market information, and the scene is dimly lit.',
    );
  });

  test('does not collapse descriptive open scenes into the clear fallback', () {
    expect(
      service.sanitizeForTest(
        'The image shows a bright, sunlit path with no visible pedestrians '
        'or obstacles in the immediate vicinity.',
      ),
      'A bright, sunlit path with no visible pedestrians or obstacles in the immediate vicinity.',
    );
  });

  test('keeps parked motorcycles near a street as a natural description', () {
    expect(
      service.sanitizeForTest(
        'The image depicts a pedestrian walkway with motorcycles parked on '
        'the right side, and in the distance to the left is an open street.',
      ),
      'A pedestrian walkway with motorcycles parked on the right side, and '
      'in the distance to the left is an open street.',
    );
  });

  test('still normalizes explicit traffic scenes', () {
    expect(
      service.sanitizeForTest(
        'The image depicts a crosswalk ahead with cars moving through the '
        'intersection.',
      ),
      'Careful, traffic area ahead with a crosswalk.',
    );
  });

  test('still drops obvious prompt echoes', () {
    expect(
      service.sanitizeForTest(
        'You are a visually impaired user assistant. '
        'No extra explanation. The path ahead is clear.',
      ),
      '',
    );
  });
}
