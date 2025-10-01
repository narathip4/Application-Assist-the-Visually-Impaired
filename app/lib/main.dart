import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'screens/camera_screen.dart';
import 'services/model_loader.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Simple download
  await ModelLoader.ensureModelsDownloaded();

  // Check if ready
  if (await ModelLoader.isReady()) {
    final path = await ModelLoader.getModelPath(
      'decoder_model_merged_int8.onnx',
    );
    print('Model path: $path');
  }

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
