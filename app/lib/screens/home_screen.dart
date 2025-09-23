import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';

class HomeScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  const HomeScreen({Key? key, required this.cameras}) : super(key: key);

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  CameraController? controller;
  bool isInitialized = false;
  bool isPermissionGranted = false;
  int currentCameraIndex = 0; // Track current camera
  bool isSwitching = false; // Track if camera is switching

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
      body: _buildBody(),
      // Temporary way to test camera switching - you can remove this later
      floatingActionButton: widget.cameras.length > 1
          ? FloatingActionButton(
              onPressed: switchCamera,
              backgroundColor: Colors.white.withOpacity(0.3),
              child: Icon(Icons.flip_camera_ios, color: Colors.white),
            )
          : null,
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
      ],
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
