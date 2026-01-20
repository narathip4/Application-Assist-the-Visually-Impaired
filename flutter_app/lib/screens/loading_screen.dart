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
  bool _bootstrapping = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _pulse = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);

    _bootstrap();
  }

  Future<void> _bootstrap() async {
    if (_bootstrapping) return;
    _bootstrapping = true;

    try {
      if (!mounted) return;
      setState(() {
        _error = null;
        _status = 'Initializing vision model...';
      });

      final vlm = FastVlmService(
        AppConfig.vlmBaseUrl,
        timeout: const Duration(seconds: 90),
      );

      // Warm-up (kept as-is; safe even if no-op)
      setState(() => _status = 'Warming up model...');
      await vlm.ensureInitialized();

      setState(() => _status = 'Detecting cameras...');
      final cams = await availableCameras();
      if (cams.isEmpty) {
        throw StateError('No camera detected on device');
      }

      if (!mounted) return;

      // Use fade transition to “match RN” (smooth + consistent feel)
      await Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => CameraScreen(cameras: cams, vlmService: vlm),
          transitionsBuilder: (_, animation, __, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          transitionDuration: const Duration(milliseconds: 200),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      _bootstrapping = false;
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
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _error != null ? _buildError(cs) : _buildProgress(cs),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProgress(ColorScheme cs) {
    return Column(
      key: const ValueKey('progress'),
      mainAxisSize: MainAxisSize.min,
      children: [
        ScaleTransition(
          scale: _pulse,
          child: Icon(Icons.auto_awesome, size: 72, color: cs.primary),
        ),
        const SizedBox(height: 16),
        Text(
          _status,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            height: 1.3,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: 40,
          height: 40,
          child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
        ),
        const SizedBox(height: 10),
        Text(
          'Please keep the app open',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildError(ColorScheme cs) {
    final msg = _error ?? 'Unknown error';
    return Column(
      key: const ValueKey('error'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline, size: 64, color: cs.error),
        const SizedBox(height: 12),
        Text(
          'Initialization failed',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          msg,
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            OutlinedButton(
              onPressed: () => SystemNavigator.pop(),
              child: const Text('Exit'),
            ),
            FilledButton(
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
