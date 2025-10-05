import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/fast_vlm_service.dart';

class CameraScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  // final FastVlmService? vlmService;

  const CameraScreen({super.key, required this.cameras});

  // const CameraScreen({super.key, required this.cameras, this.vlmService});

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

  // late final FastVlmService _vlmService;

  bool _isModelLoading = true;
  bool _isModelReady = false;
  bool _isProcessingFrame = false;
  bool _isWarmUpRunning = false;
  bool _canRetryWarmUp = true;

  String? _modelError;
  String displayText =
      'à¸à¸³à¸¥à¸±à¸‡à¹€à¸•à¸£à¸µà¸¢à¸¡à¸£à¸°à¸šà¸šà¸Šà¹ˆà¸§à¸¢à¸šà¸£à¸£à¸¢à¸²à¸¢à¸ à¸²à¸ž...';
  String? errorMessage;

  DateTime? _lastInferenceTime;
  final Duration _inferenceInterval = const Duration(milliseconds: 900);

  @override
  void initState() {
    super.initState();
    // _vlmService = widget.vlmService ?? FastVlmService();
    _warmUpModel();
    _initializeCamera();
  }

  Future<void> _warmUpModel() async {
    if (_isWarmUpRunning) return;
    _isWarmUpRunning = true;
    setState(() {
      _isModelLoading = true;
      _isModelReady = false;
      _modelError = null;
      displayText =
          'à¸à¸³à¸¥à¸±à¸‡à¹€à¸•à¸£à¸µà¸¢à¸¡à¹‚à¸¡à¹€à¸”à¸¥à¸šà¸£à¸£à¸¢à¸²à¸¢à¸ à¸²à¸ž...';
      _canRetryWarmUp = true;
    });

    try {
      // await _vlmService.ensureInitialized();
      if (!mounted) return;
      setState(() {
        _isModelReady = true;
        displayText = 'à¸žà¸£à¹‰à¸­à¸¡à¸šà¸£à¸£à¸¢à¸²à¸¢à¸ à¸²à¸žà¹à¸¥à¹‰à¸§';
        _modelError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isModelReady = false;
        _modelError = e.toString();
        displayText =
            'à¹€à¸à¸´à¸”à¸‚à¹‰à¸­à¸œà¸´à¸”à¸žà¸¥à¸²à¸”à¹ƒà¸™à¸à¸²à¸£à¹€à¸•à¸£à¸µà¸¢à¸¡à¹‚à¸¡à¹€à¸”à¸¥\n$e';
      });
    } finally {
      _isWarmUpRunning = false;
      if (mounted) {
        setState(() => _isModelLoading = false);
      }
    }
  }

  Future<void> _initializeCamera() async {
    PermissionStatus status;
    try {
      status = await Permission.camera.request();
    } catch (e) {
      debugPrint('Permission request failed: $e');
      status = PermissionStatus.granted;
    }
    if (!mounted) return;

    if (status == PermissionStatus.granted) {
      setState(() {
        isPermissionGranted = true;
        errorMessage = null;
      });
      if (widget.cameras.isNotEmpty) {
        await _setupCamera(currentCameraIndex);
      }
    } else {
      setState(() => isPermissionGranted = false);
    }
  }

  Future<void> _setupCamera(int index) async {
    if (widget.cameras.isEmpty) return;

    if (controller != null) {
      try {
        if (controller!.value.isStreamingImages) {
          await controller!.stopImageStream();
        }
      } catch (e) {
        debugPrint('Error stopping previous image stream: $e');
      } finally {
        await controller?.dispose();
      }
    }

    final newController = CameraController(
      widget.cameras[index],
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await newController.initialize();
      if (!mounted) return;

      await newController.setFlashMode(FlashMode.off);
      await newController.startImageStream(_handleCameraImage);

      setState(() {
        controller = newController;
        isInitialized = true;
        isSwitching = false;
        isFlashOn = false;
        errorMessage = null;
        _lastInferenceTime = null;
        _isProcessingFrame = false;
      });
    } catch (e) {
      debugPrint('Error initializing camera: $e');
      await newController.dispose();
      setState(() {
        isSwitching = false;
        errorMessage =
            "à¹„à¸¡à¹ˆà¸ªà¸²à¸¡à¸²à¸£à¸–à¹€à¸›à¸´à¸”à¸à¸¥à¹‰à¸­à¸‡à¹„à¸”à¹‰";
        _isProcessingFrame = false;
        _lastInferenceTime = null;
      });
    }
  }

  Future<void> switchCamera() async {
    if (widget.cameras.length < 2 || isSwitching) return;

    setState(() {
      isSwitching = true;
      isInitialized = false;
    });

    currentCameraIndex = (currentCameraIndex + 1) % widget.cameras.length;
    await _setupCamera(currentCameraIndex);
  }

  // âœ… Fixed: async IIFE, no catchError misuse
  void _handleCameraImage(CameraImage image) {
    if (_isModelLoading) return;

    if (!_isModelReady) {
      if (_modelError != null && _canRetryWarmUp && !_isWarmUpRunning) {
        _warmUpModel();
      }
      return;
    }

    final now = DateTime.now();
    if (_isProcessingFrame) return;
    if (_lastInferenceTime != null &&
        now.difference(_lastInferenceTime!) < _inferenceInterval) {
      return;
    }

    _isProcessingFrame = true;
    if (mounted && !_isModelLoading) {
      setState(
        () => displayText = 'à¸à¸³à¸¥à¸±à¸‡à¸šà¸£à¸£à¸¢à¸²à¸¢à¸ à¸²à¸ž...',
      );
    }

    () async {
      try {
        // final result = await _vlmService.describeCameraImage(image);
        if (!mounted) return;
        setState(() {
          // displayText = result;
          _modelError = null;
        });
      } catch (error, stack) {
        debugPrint('FastVLM error: $error\n$stack');
        if (!mounted) return;
        setState(() {
          _modelError = error.toString();
          displayText =
              'à¹„à¸¡à¹ˆà¸ªà¸²à¸¡à¸²à¸£à¸–à¸›à¸£à¸°à¸¡à¸§à¸¥à¸œà¸¥à¸ à¸²à¸žà¹„à¸”à¹‰\n$error';
        });
      } finally {
        _lastInferenceTime = DateTime.now();
        _isProcessingFrame = false;
      }
    }();
  }

  Future<void> toggleFlash() async {
    if (controller == null || !controller!.value.isInitialized) return;
    try {
      final newMode = isFlashOn ? FlashMode.off : FlashMode.torch;
      await controller!.setFlashMode(newMode);
      setState(() => isFlashOn = !isFlashOn);
    } catch (e) {
      debugPrint('Error toggling flash: $e');
    }
  }

  Future<void> takePicture() async {
    if (controller == null ||
        !controller!.value.isInitialized ||
        controller!.value.isTakingPicture) {
      return;
    }
    try {
      final image = await controller!.takePicture();
      debugPrint('Picture taken: ${image.path}');
    } catch (e) {
      debugPrint('Error taking picture: $e');
    }
  }

  void toggleSound() {
    setState(() => isSoundEnabled = !isSoundEnabled);
    debugPrint('Sound ${isSoundEnabled ? 'enabled' : 'disabled'}');
  }

  void openSettings() {
    debugPrint('Opening settings...');
  }

  @override
  void dispose() {
    final currentController = controller;
    controller = null;
    if (currentController != null) {
      try {
        if (currentController.value.isStreamingImages) {
          currentController.stopImageStream();
        }
      } catch (e) {
        debugPrint('Error stopping image stream on dispose: $e');
      }
      currentController.dispose();
    }
    // _vlmService.dispose();
    super.dispose();
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
          _circleButton(Icons.settings, openSettings),
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
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isModelLoading || _isProcessingFrame)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        _isModelLoading
                            ? 'à¸à¸³à¸¥à¸±à¸‡à¹€à¸•à¸£à¸µà¸¢à¸¡à¹‚à¸¡à¹€à¸”à¸¥...'
                            : 'à¸à¸³à¸¥à¸±à¸‡à¸šà¸£à¸£à¸¢à¸²à¸¢à¸ à¸²à¸ž...',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
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
      onTap: onTap,
      child: Container(
        width: 70,
        height: 70,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          border: Border.all(color: Colors.grey.shade400, width: 3),
        ),
        child: Center(
          child: Container(
            width: 60,
            height: 60,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
            ),
          ),
        ),
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
            _shutterButton(takePicture),
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
          const SizedBox(height: 12),
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
        child: iconSize > 0 ? Icon(icon, color: color, size: iconSize) : null,
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
