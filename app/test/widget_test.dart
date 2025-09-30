import 'package:app/screens/camera_screen.dart';
import 'package:app/services/fast_vlm_service.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeFastVlmService extends FastVlmService {
  bool _ready = false;

  @override
  Future<void> ensureInitialized() async {
    _ready = true;
  }

  @override
  bool get isReady => _ready;

  @override
  Future<String> describeCameraImage(CameraImage cameraImage) async {
    return 'คำอธิบายจากการทดสอบ';
  }
}

void main() {
  testWidgets('Camera screen shows warm-up and ready states', (tester) async {
    final fakeService = _FakeFastVlmService();

    await tester.pumpWidget(
      MaterialApp(
        home: CameraScreen(
          cameras: const <CameraDescription>[],
          vlmService: fakeService,
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(fakeService.isReady, isTrue);
    expect(find.textContaining('เกิดข้อผิดพลาด'), findsNothing);
  });
}
