import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';

class CameraScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  const CameraScreen({Key? key, required this.cameras}) : super(key: key);

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
  String? errorMessage;
  String displayText =
      "Text that text-to-speech will read appears here"; // Text to display

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    final status = await Permission.camera.request();
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

    await controller?.dispose();

    final newController = CameraController(
      widget.cameras[index],
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await newController.initialize();
      if (!mounted) return;

      // Reset flash เป็น off ทุกครั้ง
      await newController.setFlashMode(FlashMode.off);

      setState(() {
        controller = newController;
        isInitialized = true;
        isSwitching = false;
        isFlashOn = false;
        errorMessage = null;
      });
    } catch (e) {
      debugPrint('Error initializing camera: $e');
      setState(() {
        isSwitching = false;
        errorMessage = "ไม่สามารถเปิดกล้องได้";
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
        controller!.value.isTakingPicture)
      return;

    try {
      final image = await controller!.takePicture();
      debugPrint('Picture taken: ${image.path}');
      // TODO: ส่ง path ไปหน้าอื่นหรือ process ต่อ
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
    controller?.dispose();
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
        // Camera Preview เต็มจอ
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
      bottom: 120, // Position above the bottom controls
      left: 20,
      right: 20,
      child: Container(
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.7),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.3), width: 1),
        ),
        child: Text(
          displayText,
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w400,
          ),
          textAlign: TextAlign.center,
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
        children: [
          const CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
          const SizedBox(height: 16),
          Text(
            isSwitching ? 'Switching Camera...' : 'Loading Camera...',
            style: const TextStyle(color: Colors.white),
          ),
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
        child: iconSize > 0
            ? Icon(icon, color: color, size: iconSize)
            : null, // สำหรับ shutter button
      ),
    );
  }
}

// Painter สำหรับ sight
class _SightPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    const len = 20.0;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);

    // มุม
    canvas.drawLine(rect.topLeft, rect.topLeft + Offset(len, 0), paint);
    canvas.drawLine(rect.topLeft, rect.topLeft + Offset(0, len), paint);
    canvas.drawLine(rect.topRight, rect.topRight - Offset(len, 0), paint);
    canvas.drawLine(rect.topRight, rect.topRight + Offset(0, len), paint);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft + Offset(len, 0), paint);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft - Offset(0, len), paint);
    canvas.drawLine(rect.bottomRight, rect.bottomRight - Offset(len, 0), paint);
    canvas.drawLine(rect.bottomRight, rect.bottomRight - Offset(0, len), paint);

    // crosshair
    canvas.drawCircle(rect.center, 2, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
