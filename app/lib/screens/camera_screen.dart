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
  bool _canRetryWarmUp = true;

  // press and hold
  bool _isLongPressing = false;
  bool _shouldProcessImage = false;

  String? _modelError;
  String displayText = 'Press and hold shutter button to analyze';
  String? errorMessage;

  DateTime? _lastInferenceTime;
  final Duration _inferenceInterval = const Duration(
    milliseconds: 1500,
  ); // 1.5 seconds between inferences
  @override
  void initState() {
    super.initState();
    _vlmService = widget.vlmService ?? FastVlmService();
    _initializeCamera();
    _warmUpModel();
  }

  Future<void> _warmUpModel() async {
    if (_isWarmUpRunning) return;
    _isWarmUpRunning = true;
    setState(() {
      _isModelLoading = true;
      _modelError = null;
    });

    try {
      await _vlmService.ensureInitialized();
      setState(() {
        _isModelReady = true;
        displayText = 'Press and hold shutter button to analyze';
      });
    } catch (e) {
      setState(() {
        _isModelReady = false;
        _modelError = e.toString();
        displayText = 'Model load failed';
      });
    } finally {
      _isWarmUpRunning = false;
      setState(() => _isModelLoading = false);
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
      setState(() => errorMessage = 'Camera permission error');
    }
  }

  Future<void> _setupCamera(int index) async {
    if (widget.cameras.isEmpty) return;

    if (controller != null) {
      try {
        if (controller!.value.isStreamingImages) {
          await controller!.stopImageStream();
        }
      } catch (_) {}
      await controller?.dispose();
      controller = null;
    }

    await Future.delayed(const Duration(milliseconds: 300));

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

      await newController.setFlashMode(FlashMode.off);

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
    setState(() {
      isSwitching = true;
      isInitialized = false;
      _shouldProcessImage = false; // stop processing when switching
    });

    currentCameraIndex = (currentCameraIndex + 1) % widget.cameras.length;
    await _setupCamera(currentCameraIndex);
  }

  Future<void> _handleCameraImage(CameraImage image) async {
    // Prevent re-entrancy: skip if already processing
    if (_isProcessingFrame || !_shouldProcessImage) return;
    if (!_isModelReady || _isModelLoading) return;

    final now = DateTime.now();
    if (_lastInferenceTime != null &&
        now.difference(_lastInferenceTime!) < _inferenceInterval) {
      return;
    }

    _isProcessingFrame = true;
    _lastInferenceTime = now;

    if (mounted) {
      setState(() => displayText = 'Analyzing scene...');
    }

    try {
      final result = await _vlmService.describeCameraImage(image);
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

      // Add a small delay to let memory and GC settle
      await Future.delayed(const Duration(milliseconds: 150));
    }
  }

  Future<void> toggleFlash() async {
    if (controller == null || !controller!.value.isInitialized) return;
    try {
      final newMode = isFlashOn ? FlashMode.off : FlashMode.torch;
      await controller!.setFlashMode(newMode);
      setState(() => isFlashOn = !isFlashOn);
    } catch (e) {
      debugPrint('Flash toggle error: $e');
    }
  }

  // start long press
  void _onLongPressStart() {
    setState(() {
      _isLongPressing = true;
      _shouldProcessImage = true;
      displayText = 'Analyzing...';
    });
  }

  // stop long press
  void _onLongPressEnd() {
    setState(() {
      _isLongPressing = false;
      _shouldProcessImage = false;
      if (!_isProcessingFrame) {
        displayText = 'Press and hold shutter button to analyze';
      }
    });
  }

  // // capture photo
  // Future<void> takePicture() async {
  //   if (controller == null ||
  //       !controller!.value.isInitialized ||
  //       controller!.value.isTakingPicture) {
  //     return;
  //   }
  //   try {
  //     final image = await controller!.takePicture();
  //     debugPrint('Picture taken: ${image.path}');
  //     // แสดงข้อความแจ้งเตือน
  //     if (mounted) {
  //       setState(() => displayText = 'Picture saved!');
  //       Future.delayed(const Duration(seconds: 2), () {
  //         if (mounted && !_shouldProcessImage) {
  //           setState(
  //             () => displayText = 'Press and hold shutter button to analyze',
  //           );
  //         }
  //       });
  //     }
  //   } catch (e) {
  //     debugPrint('Picture error: $e');
  //   }
  // }

  void toggleSound() {
    setState(() => isSoundEnabled = !isSoundEnabled);
    debugPrint('Sound ${isSoundEnabled ? 'enabled' : 'disabled'}');
  }

  @override
  void dispose() {
    _shouldProcessImage = false; // stop processing when disposing
    _disposeCamera();
    _vlmService.dispose();
    super.dispose();
  }

  Future<void> _disposeCamera() async {
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
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
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

  // long press shutter button
  Widget _shutterButton(VoidCallback onTap) {
    return GestureDetector(
      // onTap: onTap, // tap to take picture
      onLongPressStart: (_) => _onLongPressStart(), // hold to start analyze
      onLongPressEnd: (_) => _onLongPressEnd(), // release to stop analyze
      child: Container(
        width: 70,
        height: 70,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _isLongPressing
              ? Colors.green
              : Colors.white, // green when analyzing
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
            // Flip camera button (if multiple cameras)
            if (widget.cameras.length > 1)
              _circleButton(Icons.flip_camera_ios, switchCamera),

            // Center shutter button for analyze (long press)
            _shutterButton(() {}),

            // Sound toggle
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
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
