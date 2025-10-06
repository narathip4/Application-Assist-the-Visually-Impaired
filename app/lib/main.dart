import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'screens/camera_screen.dart';
import 'services/model_loader.dart';
import 'services/test_model_loader.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Models are cached - no need to clear anymore
  await ModelLoader.ensureModelsDownloaded();
  await testModelIntegrity();

  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Error initializing cameras: $e');
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Visually Impaired Assist App',
      home: CameraScreen(cameras: cameras),
      debugShowCheckedModeBanner: false,
    );
  }
}
