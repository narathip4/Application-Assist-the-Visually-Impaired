import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/fast_vlm_service.dart';

class CameraScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  final FastVlmService? vlmService;

  const CameraScreen({super.key, required this.cameras, this.vlmService});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
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

  bool _isLongPressing = false;
  bool _shouldProcessImage = false;

  String? _modelError;
  String displayText = 'Press and hold shutter button to analyze';
  String? errorMessage;

  DateTime? _lastInferenceTime;
  final Duration _inferenceInterval = const Duration(milliseconds: 2000);

  @override
  void initState() {
    super.initState();

    if (widget.vlmService == null) {
      throw StateError(
        'FastVlmService is required. Provide via CameraScreen(vlmService: ...).',
      );
    }
    _vlmService = widget.vlmService!;

    // warm up model
    _warmUpModel().then((_) => _initializeCamera());
  }

  @override
  void reassemble() {
    super.reassemble();
    _disposeCamera(); // reset camera on hot reload
  }

  @override
  void deactivate() {
    // stop camera when navigating away
    _disposeCamera();
    super.deactivate();
  }

  Future<void> _warmUpModel() async {
    if (_isWarmUpRunning) return;
    _isWarmUpRunning = true;
    if (!mounted) return;
    setState(() {
      _isModelLoading = true;
      _modelError = null;
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
        _modelError = e.toString();
        displayText = 'Model load failed';
      });
    } finally {
      _isWarmUpRunning = false;
      if (mounted) {
        setState(() => _isModelLoading = false);
      }
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
      if (!mounted) return;
      setState(() => errorMessage = 'Camera permission error');
    }
  }

  Future<void> _setupCamera(int index) async {
    if (widget.cameras.isEmpty) return;

    // close previous controller
    if (controller != null) {
      try {
        if (controller!.value.isStreamingImages) {
          await controller!.stopImageStream();
        }
      } catch (_) {}
      try {
        await controller?.dispose();
      } catch (_) {}
      controller = null;
    }

    if (!mounted) return;
    await controller?.stopImageStream().catchError((_) {});

    await Future.delayed(const Duration(milliseconds: 200));

    final newController = CameraController(
      widget.cameras[index],
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await newController.initialize();
      if (!mounted) {
        await newController.dispose();
        return;
      }

      try {
        await newController.setFlashMode(FlashMode.off);
      } catch (_) {}

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
        displayText = 'Press and hold shutter button to analyze';
      });

      await controller!.startImageStream(_handleCameraImage);
    } catch (e) {
      await newController.dispose();
      if (mounted) {
        setState(() => errorMessage = 'Camera init error: $e');
      }
    }
  }

  Future<void> switchCamera() async {
    if (widget.cameras.length < 2 || isSwitching) return;
    if (!mounted) return;

    setState(() {
      isSwitching = true;
      isInitialized = false;
      _shouldProcessImage = false; // stop processing when switching
      displayText = 'Switching camera...';
    });

    currentCameraIndex = (currentCameraIndex + 1) % widget.cameras.length;
    await _setupCamera(currentCameraIndex);
  }

  Future<void> _handleCameraImage(CameraImage image) async {
    if (!mounted || controller == null || !controller!.value.isInitialized) {
      return;
    }
    if (_isProcessingFrame || !_shouldProcessImage) {
      await Future.delayed(const Duration(milliseconds: 50));
      return;
    }
    if (!_isModelReady || _isModelLoading) return;

    // throttle frames
    final now = DateTime.now();
    if (_lastInferenceTime != null &&
        now.difference(_lastInferenceTime!) < _inferenceInterval) {
      return; // skip frame
    }
    _lastInferenceTime = now;

    _isProcessingFrame = true;
    if (mounted) {
      setState(() => displayText = 'Analyzing scene...');
    }

    try {
      final result = await _vlmService.describeCameraImage(
        image,
        maxNewTokens: 32, // 32 64
      );
      if (!mounted) return;

      setState(() {
        displayText = result;
        _modelError = null;
      });
    } catch (e) {
      debugPrint('Inference error: $e');
      if (!mounted) return;
      setState(() {
        _modelError = e.toString();
        displayText = 'Cannot analyze scene';
      });
    } finally {
      _isProcessingFrame = false;
      await Future.delayed(const Duration(milliseconds: 60));
    }
  }

  Future<void> toggleFlash() async {
    final c = controller;
    if (c == null || !c.value.isInitialized) return;

    try {
      final newMode = isFlashOn ? FlashMode.off : FlashMode.torch;
      await c.setFlashMode(newMode);
      if (!mounted) return;
      setState(() => isFlashOn = !isFlashOn);
    } catch (e) {
      debugPrint('Flash toggle error: $e');
    }
  }

  void toggleSound() {
    if (!mounted) return;
    setState(() => isSoundEnabled = !isSoundEnabled);
  }

  void _onLongPressStart() {
    if (!mounted) return;
    setState(() {
      _isLongPressing = true;
      _shouldProcessImage = true;
      displayText = 'Analyzing...';
    });
  }

  void _onLongPressEnd() {
    if (!mounted) return;
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
    _shouldProcessImage = false;
    _disposeCamera();
    _vlmService.dispose();
    super.dispose();
  }

  Future<void> _disposeCamera() async {
    final c = controller;
    if (c == null) return;

    try {
      if (c.value.isStreamingImages) {
        await c.stopImageStream();
      }
    } catch (_) {}

    try {
      await c.dispose();
    } catch (_) {}

    controller = null;
  }

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
        SizedBox.expand(
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
          _circleButton(Icons.settings, () {}),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isModelLoading || (_isProcessingFrame && _shouldProcessImage))
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(width: 12),
                    Text(
                      'Processing...',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ],
                ),
              ),
            Text(
              displayText,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w400,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _shutterButton(VoidCallback onTap) {
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
          boxShadow: _isLongPressing
              ? [
                  BoxShadow(
                    color: Colors.green.withOpacity(0.5),
                    blurRadius: 10,
                    spreadRadius: 2,
                  ),
                ]
              : null,
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
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (widget.cameras.length > 1)
              _circleButton(Icons.flip_camera_ios, switchCamera),
            _shutterButton(() {}),
            _circleButton(
              isSoundEnabled ? Icons.volume_up : Icons.volume_off,
              toggleSound,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingView() {
    return Container(
      alignment: Alignment.center,
      color: Colors.black,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
          SizedBox(height: 16),
          Text('Loading Camera...', style: TextStyle(color: Colors.white)),
        ],
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
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
  }

  Widget _buildPermissionDenied() {
    return Center(
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
  }

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
