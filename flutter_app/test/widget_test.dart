// import 'package:app/screens/camera_screen.dart';
// import 'package:app/services/fast_vlm_service.dart';
// import 'package:camera/camera.dart';
// import 'package:flutter/material.dart';
// import 'package:flutter_test/flutter_test.dart';

// class _FakeFastVlmService extends FastVlmService {
//   @override
//   bool get isReady => true;

//   @override
//   Future<void> ensureInitialized() async {
//     // Simulate some initialization delay
//     await Future.delayed(const Duration(milliseconds: 100));
//   }

//   @override
//   Future<String> describeCameraImage(
//     CameraImage frame, {
//     String prompt = "Describe scene in Thai",
//   }) async {
//     return "This is a fake description.";
//   }
// }

// void main() {
//   testWidgets('Camera screen shows warm-up and ready states', (tester) async {
//     final fakeService = _FakeFastVlmService();

//     await tester.pumpWidget(
//       MaterialApp(
//         home: CameraScreen(
//           cameras: const <CameraDescription>[],
//           vlmService: fakeService,
//         ),
//       ),
//     );

//     await tester.pumpAndSettle();

//     expect(fakeService.isReady, isTrue);
//     expect(find.textContaining('something went wrong'), findsNothing);
//   });
// }
