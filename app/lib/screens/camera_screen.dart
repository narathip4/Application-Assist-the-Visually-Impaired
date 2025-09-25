import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';

class CameraScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  const CameraScreen({Key? key, required this.cameras}) : super(key: key);

  @override
  _CameraScreenState createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? controller;
  bool isInitialized = false;
  bool isPermissionGranted = false;
  int currentCameraIndex = 0; // Track current camera
  bool isSwitching = false; // Track if camera is switching
  bool isFlashOn = false; // Track flash state
  bool isSoundEnabled = true; // Track sound state

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    final status = await Permission.camera.request();

    if (status == PermissionStatus.granted) {
      setState(() {
        isPermissionGranted = true;
      });

      if (widget.cameras.isNotEmpty) {
        await _setupCamera(currentCameraIndex);
      }
    } else {
      setState(() {
        isPermissionGranted = false;
      });
    }
  }

  Future<void> _setupCamera(int cameraIndex) async {
    if (widget.cameras.isEmpty) return;

    // Dispose previous controller
    await controller?.dispose();

    // Create new controller
    controller = CameraController(
      widget.cameras[cameraIndex],
      ResolutionPreset.high,
      enableAudio: false,
    );

    try {
      await controller!.initialize();
      if (mounted) {
        setState(() {
          isInitialized = true;
          isSwitching = false;
        });
      }
    } catch (e) {
      print('Error initializing camera: $e');
      setState(() {
        isSwitching = false;
      });
    }
  }

  Future<void> switchCamera() async {
    if (widget.cameras.length < 2 || isSwitching) return;

    setState(() {
      isSwitching = true;
      isInitialized = false;
    });

    // Find next camera
    currentCameraIndex = (currentCameraIndex + 1) % widget.cameras.length;

    await _setupCamera(currentCameraIndex);
  }

  Future<void> toggleFlash() async {
    if (controller == null || !controller!.value.isInitialized) return;

    try {
      await controller!.setFlashMode(
        isFlashOn ? FlashMode.off : FlashMode.torch,
      );
      setState(() {
        isFlashOn = !isFlashOn;
      });
    } catch (e) {
      print('Error toggling flash: $e');
    }
  }

  void toggleSound() {
    setState(() {
      isSoundEnabled = !isSoundEnabled;
    });
  }

  void openSettings() {
    // Implement settings functionality
    print('Opening settings...');
  }

  // Get camera type for current camera
  String get currentCameraType {
    if (widget.cameras.isEmpty) return 'Unknown';

    final camera = widget.cameras[currentCameraIndex];
    switch (camera.lensDirection) {
      case CameraLensDirection.front:
        return 'Front Camera';
      case CameraLensDirection.back:
        return 'Back Camera';
      case CameraLensDirection.external:
        return 'External Camera';
    }
  }

  // Check if front camera is available
  bool get hasFrontCamera {
    return widget.cameras.any(
      (camera) => camera.lensDirection == CameraLensDirection.front,
    );
  }

  // Check if back camera is available
  bool get hasBackCamera {
    return widget.cameras.any(
      (camera) => camera.lensDirection == CameraLensDirection.back,
    );
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
    if (!isPermissionGranted) {
      return _buildPermissionDenied();
    }

    if (!isInitialized || controller == null || isSwitching) {
      return _buildLoadingView();
    }

    return _buildCameraView();
  }

  Widget _buildCameraView() {
    final size = MediaQuery.of(context).size;

    return Stack(
      children: [
        // Camera Preview
        SizedBox(
          width: size.width,
          height: size.height,
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: controller!.value.previewSize!.height,
              height: controller!.value.previewSize!.width,
              child: CameraPreview(controller!),
            ),
          ),
        ),

        // Top Controls
        _buildTopControls(),

        // Camera Sight/Viewfinder
        _buildCameraSight(),

        // Bottom Controls
        _buildBottomControls(),
      ],
    );
  }

  Widget _buildTopControls() {
    return Positioned(
      top: 20,
      left: 0,
      right: 0,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Settings Button
            GestureDetector(
              onTap: openSettings,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Icon(Icons.settings, color: Colors.white, size: 24),
              ),
            ),

            // Flash Button
            GestureDetector(
              onTap: toggleFlash,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Icon(
                  isFlashOn ? Icons.flash_on : Icons.flash_off,
                  color: isFlashOn ? Colors.yellow : Colors.white,
                  size: 24,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraSight() {
    return Center(
      child: Container(
        width: 200,
        height: 200,
        decoration: BoxDecoration(),
        child: Stack(
          children: [
            // Corner brackets for viewfinder effect
            Positioned(
              top: 10,
              left: 10,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: Colors.white, width: 3),
                    left: BorderSide(color: Colors.white, width: 3),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 10,
              right: 10,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: Colors.white, width: 3),
                    right: BorderSide(color: Colors.white, width: 3),
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 10,
              left: 10,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Colors.white, width: 3),
                    left: BorderSide(color: Colors.white, width: 3),
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 10,
              right: 10,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Colors.white, width: 3),
                    right: BorderSide(color: Colors.white, width: 3),
                  ),
                ),
              ),
            ),
            // Center crosshair
            Center(
              child: Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    return Positioned(
      bottom: 50,
      left: 0,
      right: 0,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            // Switch Camera Button (Left)
            if (widget.cameras.length > 1)
              GestureDetector(
                onTap: switchCamera,
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.3),
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    Icons.flip_camera_ios,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingView() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
            SizedBox(height: 20),
            Text(
              isSwitching ? 'Switching Camera...' : 'Loading Camera...',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w300,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionDenied() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.camera_alt_outlined, size: 80, color: Colors.white54),
              SizedBox(height: 24),
              Text(
                'Camera Access Required',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 12),
              Text(
                'This app needs camera permission to function properly',
                style: TextStyle(color: Colors.white70, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 32),
              ElevatedButton(
                onPressed: () async {
                  await openAppSettings();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: Text(
                  'Open Settings',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
              ),
              SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  _initializeCamera();
                },
                child: Text(
                  'Try Again',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
