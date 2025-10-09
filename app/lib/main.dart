import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'screens/camera_screen.dart';
import 'services/model_loader.dart';
// import 'services/test_model_loader.dart';
import 'screens/loading_screen.dart';

/// Global list of available cameras.
List<CameraDescription> cameras = [];

/// Application entry point.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

/// Root of the Flutter application.
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Visually Impaired Assist App',
      theme: ThemeData.dark(),
      debugShowCheckedModeBanner: false,
      home: const StartupScreen(),
    );
  }
}

/// Handles model and camera initialization.
/// Displays a loading screen until setup completes.
class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  String _message = "Preparing application...";

  @override
  void initState() {
    super.initState();
    _initializeResources();
  }

  /// Loads models and camera resources before launching the main interface.
  Future<void> _initializeResources() async {
    try {
      setState(() => _message = "Downloading and validating model files...");
      await ModelLoader.ensureModelsDownloaded();

      // await testModelIntegrity();

      setState(() => _message = "Detecting available cameras...");
      cameras = await availableCameras();

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => CameraScreen(cameras: cameras)),
      );
    } catch (e) {
      debugPrint("Initialization error: $e");
      if (!mounted) return;
      setState(
        () => _message = "Initialization failed. Please restart the app.",
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LoadingScreen(message: _message);
  }
}
