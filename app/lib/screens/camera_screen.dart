import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';

import '../screens/setting_screen.dart';
import '../services/fast_vlm_service.dart';
import '../utils/image_utils.dart';

/// Main camera screen with integrated VLM (Vision-Language Model) analysis.
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

  String displayText = 'Press and hold shutter button to analyze';
  String? errorMessage;
  String? _modelError;

  DateTime? _lastInferenceTime;
  final Duration _inferenceInterval = const Duration(milliseconds: 1000);
  int _frameCounter = 0;

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
    if (state == AppLifecycleState.inactive) {
      await _disposeCamera();
    } else if (state == AppLifecycleState.resumed) {
      if (mounted && !_isSettingUp) {
        _setupCamera(currentCameraIndex);
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

  @override
  void deactivate() {
    _disposeCamera();
    super.deactivate();
  }

  Future<void> _warmUpModel() async {
    if (_isWarmUpRunning || !mounted) return;
    _isWarmUpRunning = true;
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

  static Future<void> _preprocessWrapper(Map<String, dynamic> args) async {
    final CameraImage image = args['image'];
    final int size = args['size'];
    ImageUtils.preprocess(image, size);
  }

  Future<void> _handleCameraImage(CameraImage image) async {
    if (!mounted ||
        controller == null ||
        !controller!.value.isInitialized ||
        !controller!.value.isStreamingImages ||
        _isProcessingFrame ||
        !_shouldProcessImage ||
        !_isModelReady ||
        _isModelLoading)
      return;

    if (++_frameCounter % 3 != 0) return;
    final now = DateTime.now();
    if (_lastInferenceTime != null &&
        now.difference(_lastInferenceTime!) < _inferenceInterval)
      return;
    _lastInferenceTime = now;

    _isProcessingFrame = true;
    if (mounted) setState(() => displayText = 'Analyzing scene...');

    try {
      await compute(_preprocessWrapper, {'image': image, 'size': 224});
      final result = await _vlmService.describeCameraImage(
        image,
        maxNewTokens: 16,
      );
      if (!mounted) return;
      setState(() => displayText = result);
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
        await Future.delayed(const Duration(milliseconds: 100));
      }
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
