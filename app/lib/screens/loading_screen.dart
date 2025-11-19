import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

import '../services/onnx_model_loader.dart';
import '../services/tokenizer_service.dart';
import '../services/fast_vlm_service.dart';
import 'camera_screen.dart';

class LoadingScreen extends StatefulWidget {
  const LoadingScreen({super.key});

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _pulse;

  String _status = 'Preparing application...';
  String? _error;

  @override
  void initState() {
    super.initState();

    // Simple pulsing animation for loading indicator
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _pulse = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);

    // Begin initialization sequence
    _bootstrap();
  }

  /// Performs all asynchronous setup steps sequentially.
  Future<void> _bootstrap() async {
    try {
      // Download or verify ONNX models
      setState(() => _status = 'Downloading and validating model files...');
      await ModelLoader.ensureModelsDownloaded(
        onProgress:
            (String fileName, double progress, int received, int total) {
              if (!mounted) return;
              final percent = total > 0
                  ? (received / total * 100).toStringAsFixed(1)
                  : '';
              setState(() => _status = 'Downloading $fileName... $percent%');
            },
      );

      // Load tokenizer configuration from disk
      setState(() => _status = 'Loading tokenizer...');
      final paths = await ModelLoader.getAllModelPaths();
      final tokenizerPath = paths['tokenizer.json']!;
      final tok = await TokenizerService.fromFile(tokenizerPath);

      // Wrap tokenizer as a Vocab adapter for the VLM service
      final vocab = _TokenizerAdapter(tok);
      final vlm = FastVlmService(
        tokenizer: vocab,
      ); // Lazy-init; not yet started

      // Detect available cameras
      setState(() => _status = 'Detecting cameras...');
      final cams = await availableCameras();
      if (cams.isEmpty) {
        throw StateError('No camera detected on device');
      }

      if (!mounted) return;

      // Navigate to main camera screen once initialization completes
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => CameraScreen(cameras: cams, vlmService: vlm),
        ),
      );
    } catch (e) {
      // Capture and display errors gracefully
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Main UI build method.
  /// Displays a loading animation or an error recovery screen.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _error != null ? _buildError() : _buildProgress(),
            ),
          ),
        ),
      ),
    );
  }

  /// Displays the loading indicator with a pulsing icon and current status.
  Widget _buildProgress() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ScaleTransition(
          scale: _pulse,
          child: const Icon(Icons.auto_awesome, size: 80),
        ),
        const SizedBox(height: 16),
        Text(
          _status,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 16),
        const SizedBox(
          width: 40,
          height: 40,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ],
    );
  }

  /// Displays an error message and recovery options.
  Widget _buildError() {
    final msg = _error ?? 'Unknown error';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, size: 64),
        const SizedBox(height: 12),
        const Text(
          'Initialization failed',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(msg, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Exits app entirely
            TextButton(
              onPressed: () => SystemNavigator.pop(),
              child: const Text('Exit'),
            ),
            const SizedBox(width: 12),
            // Retry initialization
            ElevatedButton(
              onPressed: () {
                setState(() => _error = null);
                _bootstrap();
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Adapter class for converting a `TokenizerService` into a `Vocab` interface.
///
/// Provides nominal typing compatibility with `FastVlmService` requirements.
class _TokenizerAdapter implements Vocab {
  final TokenizerService _t;
  _TokenizerAdapter(this._t);

  @override
  int get bosId => _t.bosId;

  @override
  int get eosId => _t.eosId;

  @override
  List<int> encode(String text) => _t.encode(text);

  @override
  String decode(List<int> ids) => _t.decode(ids);
}
