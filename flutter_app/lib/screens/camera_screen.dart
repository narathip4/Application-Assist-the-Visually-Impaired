import 'dart:async';

import 'widgets/camera_sight_painter.dart';
import 'widgets/circle_button.dart';
import 'widgets/display_text_box.dart';

import 'package:app/app/config.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/setting_screen.dart';

import '../services/tts/speak_policy.dart';
import '../services/tts/tts_service.dart';
import '../services/tts/speech_coordinator.dart';

import '../services/vlm/fast_vlm_service.dart';
import '../services/vlm/frame_inference.dart';

class CameraScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  final FastVlmService? vlmService;

  const CameraScreen({super.key, required this.cameras, this.vlmService});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  // -------------------- Pref keys --------------------
  static const String _kSpeechKey = 'ui.speech';
  static const String _kSubtitleKey = 'ui.subtitle';
  static const String _kStatusAnalyzing = 'Analyzing...';
  static const String _kStatusStopped = 'Stopped';

  // -------------------- Camera --------------------
  CameraController? _controller;
  int _currentCameraIndex = 0;
  bool _isInitialized = false;
  bool _isPermissionGranted = false;
  bool _isSwitchingCamera = false;
  FlashMode _desiredFlashMode = FlashMode.off;

  // -------------------- VLM --------------------
  late final FastVlmService _vlmService;
  late final FrameInference _inference;
  bool _isModelReady = false;

  // -------------------- TTS --------------------
  late final TtsService _ttsService;
  late final SpeakPolicy _speakPolicy;
  late final SpeechCoordinator _speech;

  bool _isTtsEnabled = true;
  bool _subtitleEnabled = true;

  // -------------------- Processing --------------------
  bool _shouldProcessImage = true;
  bool _isProcessingFrame = false;

  Timer? _processingTimer;

  CameraImage? _latestFrame;
  int _latestFrameTimestamp = 0;
  int _lastProcessedTimestamp = 0;
  int _droppedTicks = 0;

  static const int _dropTickLogEvery = 20;

  int _consecutiveErrors = 0;
  static const int _maxConsecutiveErrors = 3;

  // -------------------- UI --------------------
  final ValueNotifier<String> _displayText = ValueNotifier<String>(
    'Initializing...',
  );
  String? _errorMessage;

  // -------------------- Lifecycle --------------------
  bool _isDisposed = false;
  int _streamGen = 0;
  Future<void> _setupChain = Future.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _ttsService = TtsService();
    _speech = SpeechCoordinator(tts: _ttsService);
    _speakPolicy = SpeakPolicy(cooldown: const Duration(seconds: 2));

    final svc = widget.vlmService;
    if (svc == null) {
      _setError('VLM service not provided');
      return;
    }

    _vlmService = svc;
    _inference = FrameInference(vlmService: _vlmService);

    _initializeApp();
  }

  // -------------------- App Init --------------------

  Future<void> _initializeApp() async {
    try {
      await Future.wait([
        _loadUserSettings(),
        _requestCameraPermission(),
        _warmUpModel(),
        _ttsService.init(),
      ]);

      if (_isDisposed) return;

      await _ttsService.refreshSettings();

      if (_isPermissionGranted && widget.cameras.isNotEmpty) {
        await _ensureCameraInitialized(_currentCameraIndex);
      }
    } catch (e) {
      debugPrint('[CameraScreen] Init error: $e');
      _setError('Failed to initialize app');
    }
  }

  Future<void> _loadUserSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (_isDisposed) return;

    _isTtsEnabled = prefs.getBool(_kSpeechKey) ?? true;
    _subtitleEnabled = prefs.getBool(_kSubtitleKey) ?? true;
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (!mounted || _isDisposed) return;

    setState(() => _isPermissionGranted = status == PermissionStatus.granted);

    if (!_isPermissionGranted) {
      _setError('Camera permission denied');
    }
  }

  Future<void> _warmUpModel() async {
    _displayText.value = 'Loading AI model...';
    try {
      await _vlmService.ensureInitialized();
      if (!mounted || _isDisposed) return;
      setState(() => _isModelReady = true);
      _displayText.value = _shouldProcessImage
          ? _kStatusAnalyzing
          : _kStatusStopped;
    } catch (e) {
      debugPrint('[CameraScreen] Model warmup error: $e');
      _setError('AI model failed to load');
    }
  }

  // -------------------- Lifecycle --------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (_isDisposed) return;

    if (state == AppLifecycleState.paused) {
      await _speech.stop();
      _stopProcessingTimer();
      await _disposeCamera();
    } else if (state == AppLifecycleState.resumed) {
      await _loadUserSettings();
      await _ttsService.refreshSettings();
      if (_isPermissionGranted && widget.cameras.isNotEmpty) {
        await _ensureCameraInitialized(_currentCameraIndex);
      }
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);

    _stopProcessingTimer();
    _speech.stop();
    _ttsService.dispose();

    final old = _controller;
    _controller = null;
    _isInitialized = false;

    if (old != null) {
      Future.microtask(() async {
        try {
          if (old.value.isStreamingImages) await old.stopImageStream();
          await old.dispose();
        } catch (_) {}
      });
    }

    _displayText.dispose();
    super.dispose();
  }

  // -------------------- Camera Setup --------------------

  Future<void> _ensureCameraInitialized(int cameraIndex) {
    _setupChain = _setupChain.then((_) async {
      if (_isDisposed) return;

      final c = _controller;
      final alreadyOk =
          _isInitialized &&
          _currentCameraIndex == cameraIndex &&
          c != null &&
          c.value.isInitialized;

      if (!alreadyOk) {
        await _setupCamera(cameraIndex);
      }
    });

    return _setupChain;
  }

  Future<void> _setupCamera(int cameraIndex) async {
    if (_isDisposed || widget.cameras.isEmpty) return;

    await _disposeCamera();
    if (!mounted || _isDisposed) return;

    try {
      final newController = CameraController(
        widget.cameras[cameraIndex],
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await newController.initialize();
      await newController.setFlashMode(_desiredFlashMode);

      _streamGen++;
      final myGen = _streamGen;

      setState(() {
        _controller = newController;
        _currentCameraIndex = cameraIndex;
        _isInitialized = true;
        _errorMessage = null;
      });

      await newController.startImageStream((img) {
        if (_isDisposed || myGen != _streamGen) return;
        if (!_shouldProcessImage || !_isModelReady) return;

        _latestFrame = img;
        _latestFrameTimestamp = DateTime.now().millisecondsSinceEpoch;
      });

      _startProcessingTimer();
      _displayText.value = _shouldProcessImage
          ? _kStatusAnalyzing
          : _kStatusStopped;
    } catch (e) {
      debugPrint('[CameraScreen] Camera setup error: $e');
      _setError('Camera initialization failed');
    }
  }

  Future<void> _disposeCamera() async {
    _stopProcessingTimer();
    await _waitForOngoingFrameProcessing();

    final old = _controller;
    if (old == null) return;

    if (mounted && !_isDisposed) {
      setState(() {
        _controller = null;
        _isInitialized = false;
      });
      await WidgetsBinding.instance.endOfFrame;
    } else {
      _controller = null;
      _isInitialized = false;
    }

    try {
      if (old.value.isStreamingImages) await old.stopImageStream();
      await old.dispose();
    } catch (_) {}

    _latestFrame = null;
  }

  Future<void> _waitForOngoingFrameProcessing() async {
    while (_isProcessingFrame && !_isDisposed) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  // -------------------- Processing Timer --------------------

  void _startProcessingTimer() {
    _stopProcessingTimer();
    if (!_shouldProcessImage || !_isModelReady || _isDisposed) return;

    _processingTimer = Timer.periodic(AppConfig.inferenceInterval, (_) {
      if (_isDisposed || !_shouldProcessImage || !_isModelReady) return;
      if (_isProcessingFrame) {
        _countDroppedTick();
        return;
      }
      if (_latestFrame == null) {
        _countDroppedTick();
        return;
      }
      if (_latestFrameTimestamp <= _lastProcessedTimestamp) {
        _countDroppedTick();
        return;
      }

      _processLatestFrame();
    });
  }

  void _stopProcessingTimer() {
    _processingTimer?.cancel();
    _processingTimer = null;
  }

  // -------------------- Inference --------------------

  Future<void> _processLatestFrame() async {
    if (_isDisposed ||
        _isProcessingFrame ||
        !_shouldProcessImage ||
        !_isModelReady ||
        _latestFrame == null) {
      return;
    }

    if (_latestFrameTimestamp <= _lastProcessedTimestamp) return;
    _lastProcessedTimestamp = _latestFrameTimestamp;

    _isProcessingFrame = true;

    try {
      final img = _latestFrame!;
      final rotation = widget.cameras[_currentCameraIndex].sensorOrientation;

      final inferenceStartMs = DateTime.now().millisecondsSinceEpoch;
      final sayRaw = await _inference.describe(img, rotation: rotation);
      final inferenceLatencyMs =
          DateTime.now().millisecondsSinceEpoch - inferenceStartMs;
      debugPrint('[Inference] latency=${inferenceLatencyMs}ms');
      if (_isDisposed || !_shouldProcessImage) return;

      _consecutiveErrors = 0;

      final say = sayRaw.trim();
      if (say.isEmpty) {
        _displayText.value = AppConfig.fallbackText;
        return;
      }

      _displayText.value = say;

      if (!_isTtsEnabled) return;

      final decision = _speech.evaluate(say);

      if (!decision.allowSpeak) return;

      final speakDecision = _speakPolicy.decide(
        description: say,
        isCritical: decision.isCritical,
      );
      if (!speakDecision.shouldSpeak) return;

      await _speech.speak(
        speakDecision.text,
        isCritical: decision.isCritical,
        ttsEnabled: _isTtsEnabled,
      );
    } catch (e) {
      _consecutiveErrors++;
      debugPrint('[Inference] Error: $e ($_consecutiveErrors)');

      _displayText.value = AppConfig.fallbackText;
      if (_consecutiveErrors >= _maxConsecutiveErrors) {
        await Future.delayed(const Duration(seconds: 3));
        _consecutiveErrors = 0;
      }
    } finally {
      _isProcessingFrame = false;
    }
  }

  void _countDroppedTick() {
    _droppedTicks++;
    if (_droppedTicks % _dropTickLogEvery == 0) {
      debugPrint('[Inference] droppedTicks=$_droppedTicks');
    }
  }

  // -------------------- Controls --------------------

  Future<void> _switchCamera() async {
    if (_isDisposed || widget.cameras.length < 2 || _isSwitchingCamera) return;

    if (mounted && !_isDisposed) {
      setState(() => _isSwitchingCamera = true);
    } else {
      _isSwitchingCamera = true;
    }

    _displayText.value = 'Switching camera...';
    _shouldProcessImage = false;

    try {
      _stopProcessingTimer();
      await _speech.stop();
      await _waitForOngoingFrameProcessing();

      final newIndex = (_currentCameraIndex + 1) % widget.cameras.length;
      await _ensureCameraInitialized(newIndex);

      _shouldProcessImage = true;
      _startProcessingTimer();
      _displayText.value = _kStatusAnalyzing;
    } finally {
      if (mounted && !_isDisposed) {
        setState(() => _isSwitchingCamera = false);
      } else {
        _isSwitchingCamera = false;
      }
    }
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final newMode = _desiredFlashMode == FlashMode.off
        ? FlashMode.torch
        : FlashMode.off;
    await controller.setFlashMode(newMode);
    if (!mounted || _isDisposed) return;
    setState(() => _desiredFlashMode = newMode);
  }

  void _toggleProcessing() {
    if (_isDisposed) return;

    setState(() => _shouldProcessImage = !_shouldProcessImage);

    if (_shouldProcessImage) {
      _displayText.value = _kStatusAnalyzing;
      _startProcessingTimer();
    } else {
      _displayText.value = _kStatusStopped;
      _stopProcessingTimer();
      _speech.stop();
    }
  }

  void _toggleTts() {
    if (_isDisposed) return;

    setState(() => _isTtsEnabled = !_isTtsEnabled);
    _saveSpeechPref(_isTtsEnabled);

    if (!_isTtsEnabled) {
      _speech.stop();
    }
  }

  Future<void> _saveSpeechPref(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSpeechKey, enabled);
  }

  Future<void> _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );

    await _loadUserSettings();
    await _ttsService.refreshSettings();
    if (!mounted || _isDisposed) return;
    setState(() {});
  }

  void _setError(String message) {
    if (_isDisposed) return;
    setState(() => _errorMessage = message);
    _displayText.value = message;
  }

  // -------------------- UI --------------------

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
    if (_isSwitchingCamera) return _buildLoadingView();
    if (!_isInitialized || _controller == null) return _buildLoadingView();
    return _buildCameraView();
  }

  Widget _buildCameraView() {
    final controller = _controller!;
    final previewSize = controller.value.previewSize!;
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
        Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: CustomPaint(painter: CameraSightPainter()),
          ),
        ),
        DisplayTextBox(
          textListenable: _displayText,
          isCritical: _speech.isCriticalMessage,
          subtitleEnabled: _subtitleEnabled,
        ),
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
          CircleButton(
            icon: Icons.settings,
            onTap: () => unawaited(_openSettings()),
          ),
          CircleButton(
            icon: _desiredFlashMode == FlashMode.torch
                ? Icons.flash_on
                : Icons.flash_off,
            onTap: () => unawaited(_toggleFlash()),
            color: _desiredFlashMode == FlashMode.torch
                ? Colors.yellow
                : Colors.white,
          ),
        ],
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
              CircleButton(
                icon: Icons.flip_camera_ios,
                onTap: () {
                  if (_isSwitchingCamera) return;
                  unawaited(_switchCamera());
                },
                color: _isSwitchingCamera ? Colors.white54 : Colors.white,
              )
            else
              const SizedBox(width: 44),
            _buildStartStopButton(),
            CircleButton(
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
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _shouldProcessImage ? Icons.stop : Icons.play_arrow,
              color: Colors.white,
            ),
            const SizedBox(width: 8),
            Text(
              _shouldProcessImage ? 'STOP' : 'START',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
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
          const CircularProgressIndicator(color: Colors.white),
          const SizedBox(height: 16),
          ValueListenableBuilder<String>(
            valueListenable: _displayText,
            builder: (_, text, _) =>
                Text(text, style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
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
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionDeniedView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
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
              style: TextStyle(color: Colors.white, fontSize: 20),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: openAppSettings,
              icon: const Icon(Icons.settings),
              label: const Text('Open Settings'),
            ),
          ],
        ),
      ),
    );
  }
}
