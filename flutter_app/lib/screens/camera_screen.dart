import 'dart:typed_data';
import 'package:app/app/config.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
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
  CameraController? controller;
  int currentCameraIndex = 0;
  bool isInitialized = false;
  bool isPermissionGranted = false;
  bool isSwitching = false;
  bool isFlashOn = false;
  bool isSoundEnabled = true;

  late final FastVlmService _vlmService;

  bool _isModelLoading = false;
  bool _isModelReady = false;
  bool _isProcessingFrame = false;
  bool _isWarmUpRunning = false;
  bool _isSettingUp = false;
  bool _isLongPressing = false;
  bool _shouldProcessImage = false;
  bool _isDisposed = false;

  String displayText = 'Press and hold shutter button to analyze';
  String? errorMessage;
  // String? _modelError;

  DateTime? _lastInferenceTime;

  // Cloud inference: do NOT run too frequently
  final Duration _inferenceInterval = AppConfig.inferenceInterval;

  // int _frameCounter = 0;
  String? _lastResult;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.vlmService == null) {
      throw StateError('FastVlmService is required');
    }
    _vlmService = widget.vlmService!;
    _warmUpModel();
    _initializeCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    final c = controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.paused) {
      await _disposeCamera();
    } else if (state == AppLifecycleState.resumed) {
      if (mounted && !_isSettingUp) {
        await _setupCamera(currentCameraIndex);
      }
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    _disposeCamera().then((_) {
      if (mounted && widget.cameras.isNotEmpty) {
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _setupCamera(currentCameraIndex);
        });
      }
    });
  }

  // @override
  // void deactivate() {
  //   _disposeCamera();
  //   super.deactivate();
  // }

  Future<void> _warmUpModel() async {
    if (_isWarmUpRunning || !mounted) return;
    _isWarmUpRunning = true;
    setState(() {
      _isModelLoading = true;
      // _modelError = null;
    });

    try {
      await _vlmService.ensureInitialized();
      if (!mounted) return;
      setState(() {
        _isModelReady = true;
        displayText = 'Press and hold shutter button to analyze';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isModelReady = false;
        // _modelError = e.toString();
        displayText = 'Model init failed';
      });
    } finally {
      _isWarmUpRunning = false;
      if (mounted) setState(() => _isModelLoading = false);
    }
  }

  Future<void> _initializeCamera() async {
    try {
      final status = await Permission.camera.request();
      if (!mounted) return;

      if (status == PermissionStatus.granted) {
        setState(() => isPermissionGranted = true);
        if (widget.cameras.isNotEmpty) {
          await _setupCamera(currentCameraIndex);
        }
      } else {
        setState(() => isPermissionGranted = false);
      }
    } catch (e) {
      debugPrint('Camera permission error: $e');
      if (mounted) setState(() => errorMessage = 'Camera permission error');
    }
  }

  Future<void> _setupCamera(int index) async {
    if (_isDisposed) return;

    if (widget.cameras.isEmpty || _isSettingUp) return;
    _isSettingUp = true;
    try {
      await _disposeCamera();
      if (!mounted) return;
      await Future.delayed(const Duration(milliseconds: 250));

      final newController = CameraController(
        widget.cameras[index],
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await newController.initialize();
      if (!mounted || _isDisposed) {
        await newController.dispose();
        return;
      }
      
      await newController.setFlashMode(FlashMode.off);
      if (!mounted) {
        await newController.dispose();
        return;
      }

      setState(() {
        controller = newController;
        isInitialized = true;
        isSwitching = false;
        isFlashOn = false;
        errorMessage = null;
      });

      await controller!.startImageStream(_handleCameraImage);
    } catch (e) {
      debugPrint('Camera setup error: $e');
      if (mounted) {
        setState(() {
          errorMessage = 'Camera init error: $e';
          isInitialized = false;
          isSwitching = false;
        });
      }
    } finally {
      _isSettingUp = false;
    }
  }

  Future<void> switchCamera() async {
    if (widget.cameras.length < 2 || isSwitching || _isSettingUp) return;
    setState(() {
      isSwitching = true;
      isInitialized = false;
      _shouldProcessImage = false;
      displayText = 'Switching camera...';
    });
    currentCameraIndex = (currentCameraIndex + 1) % widget.cameras.length;
    await _setupCamera(currentCameraIndex);
  }

  // // Isolate worker: CameraImage(YUV420) -> JPEG bytes (resized)
  // static Uint8List _toJpegWrapper(Map<String, dynamic> args) {
  //   final CameraImage image = args['image'] as CameraImage;
  //   final int maxSide = args['maxSide'] as int;
  //   final int jpegQuality = args['jpegQuality'] as int;

  //   return ImageUtils.cameraImageToJpeg(
  //     image,
  //     maxSide: maxSide,
  //     jpegQuality: jpegQuality,
  //   );
  // }

  Future<void> _handleCameraImage(CameraImage image) async {
    if (_isDisposed) return;

    if (!mounted ||
        controller == null ||
        !controller!.value.isInitialized ||
        !controller!.value.isStreamingImages ||
        _isProcessingFrame ||
        !_shouldProcessImage ||
        !_isModelReady ||
        _isModelLoading) {
      return;
    }

    // reduce CPU load
    // if (++_frameCounter % 6 != 0) return;

    // throttle requests
    final now = DateTime.now();
    if (_lastInferenceTime != null &&
        now.difference(_lastInferenceTime!) < _inferenceInterval) {
      return;
    }

    // reserve slot immediately (prevents overlap)
    _lastInferenceTime = now;
    _isProcessingFrame = true;
    if (mounted) setState(() => displayText = 'Analyzing scene...');

    try {
      final jpegBytes = await compute(yuvToJpegIsolate, {
        'image': image,
        'maxSide': AppConfig.jpegMaxSide,
        'jpegQuality': AppConfig.jpegQuality,
      });

      // convert to jpeg in isolate
      // final Uint8List jpegBytes = await compute(_toJpegWrapper, {
      //   'image': image,
      //   'maxSide': 512,
      //   'jpegQuality': 70,
      // });

      final result = await _vlmService.describeJpegBytes(
        jpegBytes,
        prompt: AppConfig.prompt,
        maxNewTokens: AppConfig.maxNewTokens,
      );

      if (!mounted) return;

      final cleaned = result.trim();
      if (cleaned.isNotEmpty) {
        // avoid repeating the same message over and over
        if (cleaned != _lastResult) {
          _lastResult = cleaned;
          setState(() => displayText = cleaned);

          // Optional: TTS hook point (if you add it later)
          // if (isSoundEnabled) await _tts.speak(cleaned);
        } else {
          setState(() => displayText = cleaned);
        }
      } else {
        setState(() => displayText = 'No result');
      }
    } catch (e) {
      debugPrint('Inference error: $e');
      if (mounted) setState(() => displayText = 'Cannot analyze scene');
    } finally {
      _isProcessingFrame = false;
    }
  }

  Future<void> toggleFlash() async {
    final c = controller;
    if (c == null || !c.value.isInitialized) return;
    try {
      final newMode = isFlashOn ? FlashMode.off : FlashMode.torch;
      await c.setFlashMode(newMode);
      setState(() => isFlashOn = !isFlashOn);
    } catch (e) {
      debugPrint('Flash toggle error: $e');
    }
  }

  void toggleSound() => setState(() => isSoundEnabled = !isSoundEnabled);

  void _onLongPressStart() {
    setState(() {
      _isLongPressing = true;
      _shouldProcessImage = true;
      displayText = 'Analyzing...';
    });
  }

  void _onLongPressEnd() {
    setState(() {
      _isLongPressing = false;
      _shouldProcessImage = false;
      if (!_isProcessingFrame) {
        displayText = 'Press and hold shutter button to analyze';
      }
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _shouldProcessImage = false;
    _disposeCamera();
    super.dispose();
  }

  Future<void> _disposeCamera() async {
    final c = controller;
    controller = null;
    if (c == null) return;

    try {
      if (c.value.isStreamingImages) {
        await c.stopImageStream();
      }
    } catch (_) {}

    try {
      await c.dispose();
    } catch (_) {}
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (!isPermissionGranted) return _buildPermissionDenied();
    if (errorMessage != null) return _buildErrorView();
    if (!isInitialized || controller == null || isSwitching) {
      return _buildLoadingView();
    }
    return _buildCameraView();
  }

  Widget _buildCameraView() {
    return Stack(
      children: [
        Positioned.fill(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: controller!.value.previewSize!.height,
              height: controller!.value.previewSize!.width,
              child: CameraPreview(controller!),
            ),
          ),
        ),
        _buildTopControls(),
        _buildCameraSight(),
        _buildTextDisplayBox(),
        _buildBottomControlsContainer(),
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
          _circleButton(Icons.settings, () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            );
          }),
          _circleButton(
            isFlashOn ? Icons.flash_on : Icons.flash_off,
            toggleFlash,
            color: isFlashOn ? Colors.yellow : Colors.white,
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
        child: CustomPaint(painter: _SightPainter()),
      ),
    );
  }

  Widget _buildTextDisplayBox() {
    return Positioned(
      bottom: 120,
      left: 20,
      right: 20,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.7),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24, width: 1),
        ),
        child: Text(
          displayText,
          style: const TextStyle(color: Colors.white, fontSize: 16),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _shutterButton() {
    return GestureDetector(
      onLongPressStart: (_) => _onLongPressStart(),
      onLongPressEnd: (_) => _onLongPressEnd(),
      child: Container(
        width: 70,
        height: 70,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _isLongPressing ? Colors.green : Colors.white,
          border: Border.all(
            color: _isLongPressing ? Colors.greenAccent : Colors.grey.shade400,
            width: 3,
          ),
        ),
        child: _isLongPressing
            ? const Icon(Icons.visibility, color: Colors.white, size: 32)
            : null,
      ),
    );
  }

  Widget _buildBottomControlsContainer() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        height: 100,
        color: Colors.black,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            if (widget.cameras.length > 1)
              _circleButton(Icons.flip_camera_ios, switchCamera),
            _shutterButton(),
            _circleButton(
              isSoundEnabled ? Icons.volume_up : Icons.volume_off,
              toggleSound,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingView() => const Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        SizedBox(height: 16),
        Text('Loading Camera...', style: TextStyle(color: Colors.white)),
      ],
    ),
  );

  Widget _buildErrorView() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, size: 80, color: Colors.red),
        const SizedBox(height: 16),
        Text(
          errorMessage ?? "Unknown error",
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: () => _setupCamera(currentCameraIndex),
          child: const Text('Retry'),
        ),
      ],
    ),
  );

  Widget _buildPermissionDenied() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.camera_alt_outlined, size: 80, color: Colors.white54),
        const SizedBox(height: 16),
        const Text(
          'Camera Access Required',
          style: TextStyle(color: Colors.white, fontSize: 18),
        ),
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: () => openAppSettings(),
          child: const Text('Open Settings'),
        ),
        TextButton(
          onPressed: _initializeCamera,
          child: const Text(
            'Try Again',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      ],
    ),
  );

  Widget _circleButton(
    IconData icon,
    VoidCallback onTap, {
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
        decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
        child: Icon(icon, color: color, size: iconSize),
      ),
    );
  }
}

class _SightPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    const len = 20.0;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);

    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(len, 0), paint);
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(0, len), paint);
    canvas.drawLine(rect.topRight, rect.topRight - const Offset(len, 0), paint);
    canvas.drawLine(rect.topRight, rect.topRight + const Offset(0, len), paint);
    canvas.drawLine(
      rect.bottomLeft,
      rect.bottomLeft + const Offset(len, 0),
      paint,
    );
    canvas.drawLine(
      rect.bottomLeft,
      rect.bottomLeft - const Offset(0, len),
      paint,
    );
    canvas.drawLine(
      rect.bottomRight,
      rect.bottomRight - const Offset(len, 0),
      paint,
    );
    canvas.drawLine(
      rect.bottomRight,
      rect.bottomRight - const Offset(0, len),
      paint,
    );
    canvas.drawCircle(rect.center, 2, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
