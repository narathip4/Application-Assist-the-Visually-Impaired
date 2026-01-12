// lib/screens/camera_screen.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:app/app/config.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../isolates/yuv_to_jpeg_isolate.dart';
import '../screens/setting_screen.dart';
import '../services/vlm/fast_vlm_service.dart';

class CameraScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  final FastVlmService? vlmService;

  const CameraScreen({super.key, required this.cameras, this.vlmService});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  // Camera
  CameraController? _controller;
  int _currentCameraIndex = 0;
  bool _isInitialized = false;
  bool _isPermissionGranted = false;

  // Persist user flash preference across camera switches
  FlashMode _desiredFlashMode = FlashMode.off;

  // VLM
  late final FastVlmService _vlmService;
  bool _isModelLoading = false;
  bool _isModelReady = false;

  // Processing control
  bool _shouldProcessImage = true; // auto-start enabled
  bool _isProcessingFrame = false;

  // UI
  final ValueNotifier<String> _displayText = ValueNotifier<String>(
    'Initializing...',
  );
  String? _errorMessage;
  String? _lastResult;

  // Lifecycle + cancellation
  bool _isDisposed = false;
  Completer<void>? _processingCancellation;

  // Serialize camera setup safely
  Future<void> _setupChain = Future.value();

  CameraImage? _latestImage;
  int _latestGen = 0;
  bool _inferenceLoopRunning = false;

  // Throttle + load shedding
  DateTime? _lastInferenceTime;
  int _frameCount = 0;

  // Stream generation (drop callbacks from old streams immediately)
  int _streamGen = 0;

  // Temporary message timer
  Timer? _tmpMsgTimer;
  static const Duration _tmpMsgDuration = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    final svc = widget.vlmService;
    if (svc == null) {
      _setError('VLM service not provided');
      return;
    }
    _vlmService = svc;

    _initializeApp();
  }

  Future<void> _initializeApp() async {
    await Future.wait([_requestCameraPermission(), _warmUpModel()]);

    if (_isDisposed) return;

    if (_isPermissionGranted && widget.cameras.isNotEmpty) {
      await _ensureCameraInitialized(_currentCameraIndex);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (_isDisposed) return;

    if (state == AppLifecycleState.paused) {
      await _disposeCamera();
      return;
    }

    if (state == AppLifecycleState.resumed) {
      if (_isPermissionGranted && widget.cameras.isNotEmpty) {
        await _ensureCameraInitialized(_currentCameraIndex);
      }
    }
  }

  Future<void> _requestCameraPermission() async {
    try {
      final status = await Permission.camera.request();
      if (!mounted || _isDisposed) return;

      setState(() {
        _isPermissionGranted = status == PermissionStatus.granted;
      });

      if (!_isPermissionGranted) _setError('Camera permission denied');
    } catch (e) {
      debugPrint('Camera permission error: $e');
      _setError('Failed to request camera permission');
    }
  }

  Future<void> _warmUpModel() async {
    if (_isDisposed || !mounted) return;

    setState(() {
      _isModelLoading = true;
      _errorMessage = null;
    });

    _displayText.value = 'Loading AI model...';

    try {
      await _vlmService.ensureInitialized();
      if (!mounted || _isDisposed) return;

      setState(() => _isModelReady = true);
      _displayText.value = _shouldProcessImage ? 'Analyzing...' : 'Paused';
    } catch (e) {
      debugPrint('Model initialization error: $e');
      if (!mounted || _isDisposed) return;

      setState(() => _isModelReady = false);
      _setError('AI model failed to load: ${e.toString()}');
    } finally {
      if (mounted && !_isDisposed) {
        setState(() => _isModelLoading = false);
      }
    }
  }

  Future<void> _ensureCameraInitialized(int cameraIndex) {
    _setupChain = _setupChain.then((_) async {
      if (_isDisposed) return;
      if (_isInitialized &&
          _currentCameraIndex == cameraIndex &&
          _controller != null) {
        return;
      }
      await _setupCamera(cameraIndex);
    });
    return _setupChain;
  }

  Future<void> _setupCamera(int cameraIndex) async {
    if (_isDisposed || widget.cameras.isEmpty) return;

    try {
      await _disposeCamera();
      if (!mounted || _isDisposed) return;

      final newController = CameraController(
        widget.cameras[cameraIndex],
        ResolutionPreset.medium, // Better balance of quality and performance
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await newController.initialize();
      if (!mounted || _isDisposed) {
        await newController.dispose();
        return;
      }

      await newController.setFlashMode(_desiredFlashMode);

      // New stream generation + new cancellation token
      _streamGen++;
      final old = _processingCancellation;
      if (old != null && !old.isCompleted) old.complete();
      final int myGen = _streamGen;
      _processingCancellation = Completer<void>();
      final localCancel = _processingCancellation;

      setState(() {
        _controller = newController;
        _currentCameraIndex = cameraIndex;
        _isInitialized = true;
        _errorMessage = null;
      });

      await newController.startImageStream((img) {
        if (_isDisposed) return;
        if (myGen != _streamGen) return;

        final cancel = localCancel;
        if (cancel == null || cancel.isCompleted) return;

        // เก็บ “เฟรมล่าสุด” ไว้เฉย ๆ
        _latestImage = img;
        _latestGen++;

        // ถ้ายังไม่มี loop ให้เริ่ม
        if (_shouldProcessImage && !_inferenceLoopRunning) {
          _runLatestOnlyLoop(cancel);
        }
      });

      _shouldProcessImage = true;
      _displayText.value = 'Analyzing...';
    } catch (e) {
      debugPrint('Camera setup error: $e');
      if (mounted && !_isDisposed) {
        setState(() => _isInitialized = false);
        _setError('Camera initialization failed: ${e.toString()}');
      }
    }
  }

  Future<void> _switchCamera() async {
    if (_isDisposed || widget.cameras.length < 2) return;

    if (mounted && !_isDisposed) setState(() => _isInitialized = false);
    _displayText.value = 'Switching camera...';

    final newIndex = (_currentCameraIndex + 1) % widget.cameras.length;
    await _ensureCameraInitialized(newIndex);
  }

  Future<void> _runLatestOnlyLoop(Completer<void> localCancel) async {
    if (_inferenceLoopRunning) return;
    _inferenceLoopRunning = true;

    int lastProcessedGen = -1;

    try {
      while (!_isDisposed && !localCancel.isCompleted && _shouldProcessImage) {
        if (_latestImage == null || _latestGen == lastProcessedGen) {
          await Future.delayed(const Duration(milliseconds: 30));
          continue;
        }

        final now = DateTime.now();
        if (_lastInferenceTime != null &&
            now.difference(_lastInferenceTime!) < AppConfig.inferenceInterval) {
          await Future.delayed(const Duration(milliseconds: 20));
          continue;
        }
        _lastInferenceTime = now;

        final image = _latestImage!;
        lastProcessedGen = _latestGen;

        try {
          final Uint8List jpegBytes =
              await compute(yuvToJpegIsolate, <String, dynamic>{
                'image': image,
                'maxSide': AppConfig.jpegMaxSide,
                'jpegQuality': AppConfig.jpegQuality,
              });

          if (_isDisposed || localCancel.isCompleted || !_shouldProcessImage)
            break;

          final result = await _vlmService.describeJpegBytes(
            jpegBytes,
            prompt: AppConfig.prompt,
            maxNewTokens: AppConfig.maxNewTokens,
          );

          if (_isDisposed || localCancel.isCompleted || !_shouldProcessImage)
            break;

          final cleaned = result.trim();
          _displayText.value = cleaned.isNotEmpty
              ? cleaned
              : AppConfig.fallbackText;

          if (cleaned == _lastResult) {
            await Future.delayed(const Duration(milliseconds: 400));
            continue; // ข้าม ไม่อัปเดต UI ไม่ยิงซ้ำ
          }

          _lastResult = cleaned;
          _displayText.value = cleaned;
        } catch (_) {
          if (_isDisposed || localCancel.isCompleted || !_shouldProcessImage)
            break;
          _displayText.value = AppConfig.fallbackText;
        }
      }
    } finally {
      _inferenceLoopRunning = false;
    }
  }

  Future<void> _handleCameraImage(
    CameraImage image,
    Completer<void> localCancel,
  ) async {
    if (_isDisposed) return;
    if (localCancel.isCompleted) return;

    // Shed load (CPU/network). Adjust 2~4 as needed.
    if ((++_frameCount % 3) != 0) return;

    final controller = _controller;
    if (!mounted ||
        controller == null ||
        !controller.value.isInitialized ||
        _isProcessingFrame ||
        !_shouldProcessImage ||
        !_isModelReady ||
        _isModelLoading) {
      return;
    }

    // Throttle requests
    final now = DateTime.now();
    if (_lastInferenceTime != null &&
        now.difference(_lastInferenceTime!) < AppConfig.inferenceInterval) {
      return;
    }
    _lastInferenceTime = now;

    _isProcessingFrame = true;

    try {
      final Uint8List jpegBytes =
          await compute(yuvToJpegIsolate, <String, dynamic>{
            'image': image,
            'maxSide': AppConfig.jpegMaxSide,
            'jpegQuality': AppConfig.jpegQuality,
          });

      if (_isDisposed || localCancel.isCompleted) return;

      final result = await _vlmService.describeJpegBytes(
        jpegBytes,
        prompt: AppConfig.prompt,
        maxNewTokens: AppConfig.maxNewTokens,
      );

      if (_isDisposed || localCancel.isCompleted) return;

      final cleaned = result.trim();
      if (cleaned.isNotEmpty) {
        if (cleaned != _lastResult) _lastResult = cleaned;
        _displayText.value = cleaned;
      } else {
        _displayText.value = AppConfig.fallbackText;
      }
    } catch (e) {
      debugPrint('Inference error: $e');
      if (!_isDisposed && !localCancel.isCompleted) {
        _displayText.value = AppConfig.fallbackText;
      }
    } finally {
      _isProcessingFrame = false;
    }
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    try {
      final newMode = _desiredFlashMode == FlashMode.off
          ? FlashMode.torch
          : FlashMode.off;
      await controller.setFlashMode(newMode);

      if (mounted && !_isDisposed) {
        setState(() => _desiredFlashMode = newMode);
      } else {
        _desiredFlashMode = newMode;
      }
    } catch (e) {
      debugPrint('Flash toggle error: $e');
      _showTemporaryMessage('Failed to toggle flash');
    }
  }

  void _toggleProcessing() {
    if (_isDisposed) return;

    setState(() => _shouldProcessImage = !_shouldProcessImage);

    if (_shouldProcessImage) {
      _displayText.value = 'Analyzing...';
      final cancel = _processingCancellation;
      if (cancel != null && !cancel.isCompleted && !_inferenceLoopRunning) {
        _runLatestOnlyLoop(cancel);
      }
    } else {
      _displayText.value = 'Stopped';
    }
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  Future<void> _disposeCamera() async {
    // cancel any in-flight processing immediately
    final cancel = _processingCancellation;
    if (cancel != null && !cancel.isCompleted) cancel.complete();

    _shouldProcessImage = false;
    _isProcessingFrame = false;

    final old = _controller;
    if (old == null) {
      if (mounted && !_isDisposed) {
        setState(() => _isInitialized = false);
      } else {
        _isInitialized = false;
      }
      return;
    }

    // 1) DETACH preview from widget tree first
    if (mounted && !_isDisposed) {
      setState(() {
        _controller = null;
        _isInitialized = false;
      });

      // 2) wait for the frame that removes CameraPreview to complete
      try {
        await WidgetsBinding.instance.endOfFrame;
      } catch (_) {}
    } else {
      _controller = null;
      _isInitialized = false;
    }

    // 3) now it is safe to stop stream + dispose
    try {
      if (old.value.isStreamingImages) {
        await old.stopImageStream();
      }
    } catch (e) {
      debugPrint('Error stopping stream: $e');
    }

    try {
      await old.dispose();
    } catch (e) {
      debugPrint('Error disposing controller: $e');
    }
  }

  void _setError(String message) {
    if (_isDisposed) return;
    if (mounted) setState(() => _errorMessage = message);
    _displayText.value = message;
  }

  void _showTemporaryMessage(String message) {
    _displayText.value = message;
    _tmpMsgTimer?.cancel();
    _tmpMsgTimer = Timer(_tmpMsgDuration, () {
      if (!_isDisposed) {
        _displayText.value = _shouldProcessImage ? 'Analyzing...' : 'Paused';
      }
    });
  }

  @override
  void dispose() {
    _isDisposed = true;

    // Cancel any in-flight processing
    final cancel = _processingCancellation;
    if (cancel != null && !cancel.isCompleted) cancel.complete();

    WidgetsBinding.instance.removeObserver(this);
    _tmpMsgTimer?.cancel();

    final old = _controller;
    _controller = null; // Hard detach
    _isInitialized = false;

    // Properly dispose controller without setState using unawaited
    if (old != null) {
      unawaited(
        Future.microtask(() async {
          try {
            if (old.value.isStreamingImages) {
              await old.stopImageStream();
            }
          } catch (e) {
            debugPrint('Error stopping stream in dispose: $e');
          }
          try {
            await old.dispose();
          } catch (e) {
            debugPrint('Error disposing controller: $e');
          }
        }),
      );
    }

    // CRITICAL: Dispose VLM service to prevent HTTP client leak
    // try {
    //   _vlmService.dispose();
    // } catch (e) {
    //   debugPrint('Error disposing VLM service: $e');
    // }

    _displayText.dispose();
    super.dispose();
  }

  // ================= UI =================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (!_isPermissionGranted) return _buildPermissionDeniedView();
    if (_errorMessage != null) return _buildErrorView();
    if (!_isInitialized || _controller == null) return _buildLoadingView();
    return _buildCameraView();
  }

  Widget _buildCameraView() {
    final controller = _controller;
    if (controller == null) return _buildLoadingView();

    final previewSize = controller.value.previewSize;
    if (previewSize == null) return _buildLoadingView();

    return Stack(
      children: [
        Positioned.fill(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: previewSize.height,
              height: previewSize.width,
              child: CameraPreview(controller),
            ),
          ),
        ),
        _buildTopControls(),
        _buildCameraSight(),
        _buildDisplayTextBox(),
        _buildBottomControls(),
      ],
    );
  }

  Widget _buildTopControls() {
    return Positioned(
      top: 20,
      left: 20,
      right: 20,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildCircleButton(icon: Icons.settings, onTap: _openSettings),
          _buildCircleButton(
            icon: _desiredFlashMode == FlashMode.torch
                ? Icons.flash_on
                : Icons.flash_off,
            onTap: _toggleFlash,
            color: _desiredFlashMode == FlashMode.torch
                ? Colors.yellow
                : Colors.white,
          ),
        ],
      ),
    );
  }

  Widget _buildCameraSight() {
    return Center(
      child: SizedBox(
        width: 200,
        height: 200,
        child: CustomPaint(painter: _CameraSightPainter()),
      ),
    );
  }

  Widget _buildDisplayTextBox() {
    return Positioned(
      bottom: 120,
      left: 20,
      right: 20,
      child: ValueListenableBuilder<String>(
        valueListenable: _displayText,
        builder: (context, text, child) {
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.7),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white24, width: 1),
            ),
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
          );
        },
      ),
    );
  }

  Widget _buildBottomControls() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        height: 100,
        color: Colors.black,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            if (widget.cameras.length > 1)
              _buildCircleButton(
                icon: Icons.flip_camera_ios,
                onTap: _switchCamera,
              )
            else
              const SizedBox(width: 44),
            _buildStartStopButton(),
            const SizedBox(width: 44),
          ],
        ),
      ),
    );
  }

  Widget _buildStartStopButton() {
    return GestureDetector(
      onTap: _toggleProcessing,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: BoxDecoration(
          color: _shouldProcessImage ? Colors.red : Colors.green,
          borderRadius: BorderRadius.circular(25),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _shouldProcessImage ? Icons.stop : Icons.play_arrow,
              color: Colors.white,
              size: 28,
            ),
            const SizedBox(width: 8),
            Text(
              _shouldProcessImage ? 'STOP' : 'START',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
          const SizedBox(height: 16),
          ValueListenableBuilder<String>(
            valueListenable: _displayText,
            builder: (context, text, child) =>
                Text(text, style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 80, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              _errorMessage ?? 'Unknown error',
              style: const TextStyle(color: Colors.white, fontSize: 18),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => _ensureCameraInitialized(_currentCameraIndex),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionDeniedView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.camera_alt_outlined,
              size: 80,
              color: Colors.white54,
            ),
            const SizedBox(height: 16),
            const Text(
              'Camera Access Required',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'This app needs camera access to analyze your surroundings in real-time.',
              style: TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => openAppSettings(),
              icon: const Icon(Icons.settings),
              label: const Text('Open Settings'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _requestCameraPermission,
              child: const Text(
                'Try Again',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCircleButton({
    required IconData icon,
    required VoidCallback onTap,
    Color color = Colors.white,
    Color bgColor = const Color.fromARGB(100, 0, 0, 0),
    double size = 44,
    double iconSize = 24,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: bgColor,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(icon, color: color, size: iconSize),
      ),
    );
  }
}

class _CameraSightPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    const cornerLength = 20.0;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);

    canvas.drawLine(
      rect.topLeft,
      rect.topLeft + const Offset(cornerLength, 0),
      paint,
    );
    canvas.drawLine(
      rect.topLeft,
      rect.topLeft + const Offset(0, cornerLength),
      paint,
    );
    canvas.drawLine(
      rect.topRight,
      rect.topRight - const Offset(cornerLength, 0),
      paint,
    );
    canvas.drawLine(
      rect.topRight,
      rect.topRight + const Offset(0, cornerLength),
      paint,
    );
    canvas.drawLine(
      rect.bottomLeft,
      rect.bottomLeft + const Offset(cornerLength, 0),
      paint,
    );
    canvas.drawLine(
      rect.bottomLeft,
      rect.bottomLeft - const Offset(0, cornerLength),
      paint,
    );
    canvas.drawLine(
      rect.bottomRight,
      rect.bottomRight - const Offset(cornerLength, 0),
      paint,
    );
    canvas.drawLine(
      rect.bottomRight,
      rect.bottomRight - const Offset(0, cornerLength),
      paint,
    );

    canvas.drawCircle(rect.center, 2, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
