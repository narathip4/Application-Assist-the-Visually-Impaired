// lib/screens/camera_screen.dart
import 'dart:async';

import 'package:app/app/config.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../isolates/yuv_to_jpeg_isolate.dart';
import '../screens/setting_screen.dart';
import '../services/vlm/fast_vlm_service.dart';
import '../services/tts/tts_service.dart';
import '../services/tts/speak_policy.dart';
import 'dart:typed_data';

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
  FlashMode _desiredFlashMode = FlashMode.off;

  // VLM
  late final FastVlmService _vlmService;
  bool _isModelReady = false;

  // TTS
  late final TtsService _ttsService;
  late final SpeakPolicy _speakPolicy;
  bool _isTtsEnabled = true;

  // Processing control
  bool _shouldProcessImage = true;
  bool _isProcessingFrame = false; // NEW: Track if currently processing

  // UI
  final ValueNotifier<String> _displayText =
      ValueNotifier<String>('Initializing...');
  String? _errorMessage;

  // Latest frame (latest-only) - NOW ONLY STORES REFERENCE
  CameraImage? _latestFrame;
  int _latestFrameTimestamp = 0;

  // Lifecycle / cancellation
  bool _isDisposed = false;
  int _streamGen = 0;

  Uint8List? _lastSentImageBytes;

  // Serialize setup
  Future<void> _setupChain = Future.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _ttsService = TtsService();
    _speakPolicy = SpeakPolicy(cooldown: const Duration(seconds: 2));

    final svc = widget.vlmService;
    if (svc == null) {
      _setError('VLM service not provided');
      return;
    }
    _vlmService = svc;

    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      await Future.wait([
        _requestCameraPermission(),
        _warmUpModel(),
        _ttsService.init(),
      ]);

      if (_isDisposed) return;

      if (_isPermissionGranted && widget.cameras.isNotEmpty) {
        await _ensureCameraInitialized(_currentCameraIndex);
      }
    } catch (e) {
      debugPrint('[CameraScreen] Initialization error: $e');
      _setError('Failed to initialize app');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (_isDisposed) return;

    if (state == AppLifecycleState.paused) {
      await _ttsService.stop();
      await _disposeCamera();
    } else if (state == AppLifecycleState.resumed) {
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

      if (!_isPermissionGranted) {
        _setError('Camera permission denied');
      }
    } catch (e) {
      debugPrint('[CameraScreen] Permission error: $e');
      _setError('Failed to request camera permission');
    }
  }

  Future<void> _warmUpModel() async {
    _displayText.value = 'Loading AI model...';
    try {
      await _vlmService.ensureInitialized();
      if (!mounted || _isDisposed) return;
      setState(() => _isModelReady = true);
      _displayText.value = _shouldProcessImage ? 'Analyzing...' : 'Stopped';
    } catch (e) {
      debugPrint('[CameraScreen] Model warmup error: $e');
      if (!mounted || _isDisposed) return;
      setState(() => _isModelReady = false);
      _setError('AI model failed to load');
    }
  }

  Future<void> _ensureCameraInitialized(int cameraIndex) {
    _setupChain = _setupChain.then((_) async {
      if (_isDisposed) return;
      if (_isInitialized &&
          _currentCameraIndex == cameraIndex &&
          _controller != null &&
          _controller!.value.isInitialized) {
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
        ResolutionPreset.medium, // CHANGED: medium instead of high for better performance
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await newController.initialize();
      if (!mounted || _isDisposed) {
        await newController.dispose();
        return;
      }

      await newController.setFlashMode(_desiredFlashMode);

      _streamGen++;
      final myGen = _streamGen;

      if (mounted && !_isDisposed) {
        setState(() {
          _controller = newController;
          _currentCameraIndex = cameraIndex;
          _isInitialized = true;
          _errorMessage = null;
        });
      } else {
        _controller = newController;
        _currentCameraIndex = cameraIndex;
        _isInitialized = true;
        _errorMessage = null;
      }

      // Start image stream with optimized callback
      await newController.startImageStream((CameraImage img) {
        if (_isDisposed || myGen != _streamGen) return;

        // CRITICAL FIX: Skip if already processing
        if (_isProcessingFrame || !_shouldProcessImage || !_isModelReady) {
          return;
        }

        // Store reference only (no copying yet)
        _latestFrame = img;
        _latestFrameTimestamp = DateTime.now().millisecondsSinceEpoch;

        // Trigger processing
        _processLatestFrame();
      });

      _displayText.value = _shouldProcessImage ? 'Analyzing...' : 'Stopped';
    } catch (e) {
      debugPrint('[CameraScreen] Camera setup error: $e');
      _setError('Camera initialization failed');
    }
  }

  Future<void> _processLatestFrame() async {
    if (_isProcessingFrame || _latestFrame == null) return;
    if (_isDisposed || !_shouldProcessImage || !_isModelReady) return;

    _isProcessingFrame = true;

    String? lastSay;
    int consecutiveErrors = 0;
    const maxConsecutiveErrors = 3;

    try {
      final img = _latestFrame!;
      final rotation = widget.cameras[_currentCameraIndex].sensorOrientation;

      // Copy YUV data NOW (only when we're actually processing)
      final yPlane = img.planes[0];
      final uPlane = img.planes[1];
      final vPlane = img.planes[2];

      // Convert YUV -> JPEG off main thread
      final jpegBytes = await compute(yuvToJpegIsolate, <String, dynamic>{
        'width': img.width,
        'height': img.height,
        'y': Uint8List.fromList(yPlane.bytes),
        'u': Uint8List.fromList(uPlane.bytes),
        'v': Uint8List.fromList(vPlane.bytes),
        'yRowStride': yPlane.bytesPerRow,
        'uvRowStride': uPlane.bytesPerRow,
        'uvPixelStride': uPlane.bytesPerPixel ?? 1,
        'maxSide': AppConfig.jpegMaxSide,
        'jpegQuality': AppConfig.jpegQuality,
        'rotation': rotation,
      });

      if (_isDisposed || !_shouldProcessImage) return;

      // Update preview image
      if (mounted) {
        setState(() {
          _lastSentImageBytes = jpegBytes;
        });
      } else {
        _lastSentImageBytes = jpegBytes;
      }

      // Call VLM
      final response = await _vlmService.describeJpegBytes(
        jpegBytes,
        prompt: AppConfig.prompt,
        maxNewTokens: AppConfig.maxNewTokens,
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw TimeoutException('VLM request timed out');
        },
      );

      if (_isDisposed || !_shouldProcessImage) return;

      // Reset error counter on success
      consecutiveErrors = 0;

      final say = response.say.trim();
      if (say.isEmpty) {
        _displayText.value = AppConfig.fallbackText;
      } else {
        // Skip duplicates
        if (lastSay == null || say != lastSay) {
          lastSay = say;
          _displayText.value = say;

          if (_isTtsEnabled) {
            final decision = _speakPolicy.decide(description: say);
            if (decision.shouldSpeak) {
              _ttsService.speak(decision.text);
            }
          }
        }
      }

      // Wait before allowing next frame processing
      await Future.delayed(AppConfig.inferenceInterval);

    } catch (e) {
      if (_isDisposed || !_shouldProcessImage) return;

      consecutiveErrors++;
      debugPrint('[Inference] Error: $e (consecutive: $consecutiveErrors)');

      // Back off exponentially if multiple errors
      if (consecutiveErrors >= maxConsecutiveErrors) {
        _displayText.value = 'Connection issue. Retrying...';
        await Future.delayed(const Duration(seconds: 5));
        consecutiveErrors = 0;
      } else {
        _displayText.value = AppConfig.fallbackText;
        await Future.delayed(Duration(seconds: consecutiveErrors));
      }
    } finally {
      _isProcessingFrame = false;
      
      // If we should still be processing and there's a newer frame, process it
      if (_shouldProcessImage && _isModelReady && !_isDisposed) {
        // Small delay to prevent tight loop
        await Future.delayed(const Duration(milliseconds: 100));
        if (_shouldProcessImage && !_isProcessingFrame) {
          _processLatestFrame();
        }
      }
    }
  }

  Future<void> _switchCamera() async {
    if (_isDisposed || widget.cameras.length < 2) return;

    _displayText.value = 'Switching camera...';

    // pause processing while switching
    final wasProcessing = _shouldProcessImage;
    _shouldProcessImage = false;
    await _ttsService.stop();

    // Wait for any ongoing processing to finish
    while (_isProcessingFrame && !_isDisposed) {
      await Future.delayed(const Duration(milliseconds: 50));
    }

    final newIndex = (_currentCameraIndex + 1) % widget.cameras.length;
    await _ensureCameraInitialized(newIndex);

    // restore
    _shouldProcessImage = wasProcessing;
    _displayText.value = _shouldProcessImage ? 'Analyzing...' : 'Stopped';
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    try {
      final newMode =
          _desiredFlashMode == FlashMode.off ? FlashMode.torch : FlashMode.off;
      await controller.setFlashMode(newMode);
      if (mounted && !_isDisposed) {
        setState(() => _desiredFlashMode = newMode);
      } else {
        _desiredFlashMode = newMode;
      }
    } catch (e) {
      debugPrint('[CameraScreen] Flash toggle error: $e');
    }
  }

  void _toggleProcessing() {
    if (_isDisposed) return;

    if (mounted && !_isDisposed) {
      setState(() => _shouldProcessImage = !_shouldProcessImage);
    } else {
      _shouldProcessImage = !_shouldProcessImage;
    }

    if (_shouldProcessImage) {
      _displayText.value = 'Analyzing...';
      // Trigger processing if not already running
      if (!_isProcessingFrame) {
        _processLatestFrame();
      }
    } else {
      _displayText.value = 'Stopped';
      _ttsService.stop();
    }
  }

  void _toggleTts() {
    if (_isDisposed) return;

    if (mounted && !_isDisposed) {
      setState(() => _isTtsEnabled = !_isTtsEnabled);
    } else {
      _isTtsEnabled = !_isTtsEnabled;
    }

    if (!_isTtsEnabled) {
      _ttsService.stop();
    }
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  Future<void> _disposeCamera() async {
    await _ttsService.stop();

    // Wait for processing to finish
    while (_isProcessingFrame && !_isDisposed) {
      await Future.delayed(const Duration(milliseconds: 50));
    }

    final old = _controller;
    if (old == null) {
      if (mounted && !_isDisposed) {
        setState(() => _isInitialized = false);
      } else {
        _isInitialized = false;
      }
      _latestFrame = null;
      return;
    }

    // DETACH first to avoid CameraPreview using disposed controller
    if (mounted && !_isDisposed) {
      setState(() {
        _controller = null;
        _isInitialized = false;
      });
      try {
        await WidgetsBinding.instance.endOfFrame;
      } catch (e) {
        debugPrint('[CameraScreen] endOfFrame error: $e');
      }
    } else {
      _controller = null;
      _isInitialized = false;
    }

    // stop stream then dispose
    try {
      if (old.value.isStreamingImages) {
        await old.stopImageStream();
      }
    } catch (e) {
      debugPrint('[CameraScreen] stopImageStream error: $e');
    }
    try {
      await old.dispose();
    } catch (e) {
      debugPrint('[CameraScreen] dispose error: $e');
    }

    _latestFrame = null;
  }

  void _setError(String message) {
    if (_isDisposed) return;
    if (mounted) {
      setState(() => _errorMessage = message);
    } else {
      _errorMessage = message;
    }
    _displayText.value = message;
  }

  @override
  void dispose() {
    _isDisposed = true;

    WidgetsBinding.instance.removeObserver(this);

    _ttsService.dispose();

    final old = _controller;
    _controller = null;
    _isInitialized = false;

    if (old != null) {
      // Fire and forget cleanup
      Future.microtask(() async {
        try {
          if (old.value.isStreamingImages) {
            await old.stopImageStream();
          }
        } catch (e) {
          debugPrint('[CameraScreen] Cleanup stopImageStream error: $e');
        }
        try {
          await old.dispose();
        } catch (e) {
          debugPrint('[CameraScreen] Cleanup dispose error: $e');
        }
      });
    }

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
    if (!controller.value.isInitialized) return _buildLoadingView();

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
        if (_lastSentImageBytes != null)
          Positioned(
            right: 12,
            top: 80,
            child: Container(
              width: 200,
              height: 180,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white54, width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.memory(
                _lastSentImageBytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
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
          _buildCircleButton(
            icon: Icons.settings,
            onTap: _openSettings,
          ),
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
          Color borderColor = Colors.white24;
          final lower = text.toLowerCase();
          if (lower.contains('unclear') || lower.contains('difficult')) {
            borderColor = Colors.orange;
          }

          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.7),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor, width: 2),
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
            _buildCircleButton(
              icon: _isTtsEnabled ? Icons.volume_up : Icons.volume_off,
              onTap: _toggleTts,
              color: _isTtsEnabled ? Colors.white : Colors.white54,
            ),
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
            builder: (context, text, child) {
              return Text(text, style: const TextStyle(color: Colors.white));
            },
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

    // Top-left
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(cornerLength, 0), paint);
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(0, cornerLength), paint);

    // Top-right
    canvas.drawLine(rect.topRight, rect.topRight - const Offset(cornerLength, 0), paint);
    canvas.drawLine(rect.topRight, rect.topRight + const Offset(0, cornerLength), paint);

    // Bottom-left
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft + const Offset(cornerLength, 0), paint);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft - const Offset(0, cornerLength), paint);

    // Bottom-right
    canvas.drawLine(rect.bottomRight, rect.bottomRight - const Offset(cornerLength, 0), paint);
    canvas.drawLine(rect.bottomRight, rect.bottomRight - const Offset(0, cornerLength), paint);

    // Center dot
    canvas.drawCircle(rect.center, 2, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}