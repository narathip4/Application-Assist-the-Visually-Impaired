import 'package:app/app/config.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

import '../services/vlm/fast_vlm_service.dart';
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

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _pulse = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);

    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      setState(() {
        _error = null;
        _status = 'Creating VLM service...';
      });

      // // TODO: replace with your FastVLM Space base URL (no trailing slash preferred)
      // const fastVlmBaseUrl = 'https://YOUR-SPACE-NAME.hf.space';

      final vlm = FastVlmService(
        AppConfig.vlmBaseUrl,
        // timeout can be adjusted; Free Space sometimes needs longer on cold start
        timeout: const Duration(seconds: 90),
      );

      // Optional: warm-up (no-op unless you add an endpoint; keep for future)
      setState(() => _status = 'Warming up model...');
      await vlm.ensureInitialized();

      setState(() => _status = 'Detecting cameras...');
      final cams = await availableCameras();
      if (cams.isEmpty) {
        throw StateError('No camera detected on device');
      }

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => CameraScreen(cameras: cams, vlmService: vlm),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

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
            TextButton(
              onPressed: () => SystemNavigator.pop(),
              child: const Text('Exit'),
            ),
            const SizedBox(width: 12),
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
