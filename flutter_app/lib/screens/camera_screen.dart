import 'dart:async';

import 'widgets/camera_sight_painter.dart';
import 'widgets/circle_button.dart';
import 'widgets/display_text_box.dart';

import 'package:app/app/config.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/setting_screen.dart';

import '../services/tts/speak_policy.dart';
import '../services/tts/tts_service.dart';
import '../services/tts/speech_coordinator.dart';

import '../services/translation/google_translate_service.dart';
import '../services/translation/translate_description_use_case.dart';
import '../services/vlm/fast_vlm_service.dart';
import '../services/vlm/frame_inference.dart';
import '../utils/sequence_image_utils.dart';

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
  static const String _kVibrationKey = 'ui.vibration';
  static const String _kTranslateToThaiKey = 'ui.translateToThai';
  static const String _kStatusAnalyzing = 'กำลังวิเคราะห์...';
  static const String _kStatusStopped = 'หยุดการวิเคราะห์แล้ว';
  static const double _kBlindControlSize = 58;
  static const double _kBlindIconSize = 30;

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
  late final TranslateDescriptionUseCase _translateDescription;
  bool _isModelReady = false;

  // -------------------- TTS --------------------
  late final TtsService _ttsService;
  late final SpeakPolicy _speakPolicy;
  late final SpeechCoordinator _speech;

  bool _isTtsEnabled = true;
  bool _subtitleEnabled = true;
  bool _isVibrationEnabled = true;
  bool _translateToThai = true;

  // -------------------- Processing --------------------
  bool _shouldProcessImage = true;
  bool _isProcessingFrame = false;

  Timer? _processingTimer;

  CameraImage? _latestFrame;
  final List<Uint8List> _sequenceFrameBuffer = <Uint8List>[];
  int _latestFrameTimestamp = 0;
  int _lastProcessedTimestamp = 0;
  static const int _maxAcceptableResultLagMs = 2200;
  static const int _sameSceneCooldownMs = 7000;
  int _droppedTicks = 0;

  static const int _dropTickLogEvery = 20;

  int _consecutiveErrors = 0;
  static const int _maxConsecutiveErrors = 3;
  String? _lastSpokenOrShownDescription;
  int _lastSpokenOrShownAtMs = 0;

  // -------------------- UI --------------------
  final ValueNotifier<String> _displayText = ValueNotifier<String>(
    'กำลังเริ่มต้นระบบ...',
  );
  String? _errorMessage;

  // -------------------- Lifecycle --------------------
  bool _isDisposed = false;
  bool _didPlayTtsReadyPrompt = false;
  bool _didPlayControlHintPrompt = false;
  int _streamGen = 0;
  Future<void> _setupChain = Future.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _ttsService = TtsService();
    _speech = SpeechCoordinator(tts: _ttsService);
    _speakPolicy = SpeakPolicy(
      cooldown: const Duration(seconds: 5),
      criticalMinInterval: const Duration(milliseconds: 1500),
    );

    final svc = widget.vlmService;
    if (svc == null) {
      _setError('ไม่ได้ตั้งค่าบริการโมเดลการมองเห็น');
      return;
    }

    _vlmService = svc;
    _inference = FrameInference(vlmService: _vlmService);
    _translateDescription = TranslateDescriptionUseCase(
      translator: GoogleTranslateService(timeout: const Duration(seconds: 5)),
    );

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
      if (_isTtsEnabled && !_didPlayTtsReadyPrompt) {
        _didPlayTtsReadyPrompt = true;
        unawaited(
          _speech.speak(
            'ระบบเสียงพร้อมใช้งาน',
            isCritical: true,
            ttsEnabled: true,
          ),
        );
      }
      if (_isTtsEnabled && !_didPlayControlHintPrompt) {
        _didPlayControlHintPrompt = true;
        unawaited(
          _speech.speak(
            'แตะปุ่มกลางเพื่อเริ่มหรือหยุดการวิเคราะห์ ปุ่มซ้ายล่างเปิดปิดเสียงพูด',
            isCritical: false,
            ttsEnabled: true,
          ),
        );
      }

      if (_isPermissionGranted && widget.cameras.isNotEmpty) {
        await _ensureCameraInitialized(_currentCameraIndex);
      }
    } catch (e) {
      debugPrint('[CameraScreen] Init error: $e');
      _setError('เริ่มต้นแอปไม่สำเร็จ');
    }
  }

  Future<void> _loadUserSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (_isDisposed) return;

    _isTtsEnabled = prefs.getBool(_kSpeechKey) ?? true;
    _subtitleEnabled = prefs.getBool(_kSubtitleKey) ?? true;
    _isVibrationEnabled = prefs.getBool(_kVibrationKey) ?? true;
    _translateToThai = prefs.getBool(_kTranslateToThaiKey) ?? true;
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (!mounted || _isDisposed) return;

    setState(() => _isPermissionGranted = status == PermissionStatus.granted);

    if (!_isPermissionGranted) {
      _setError('ไม่ได้รับอนุญาตให้ใช้กล้อง');
    }
  }

  Future<void> _warmUpModel() async {
    _displayText.value = 'กำลังโหลดโมเดล AI...';
    try {
      await _vlmService.ensureInitialized();
      if (!mounted || _isDisposed) return;
      setState(() => _isModelReady = true);
      _displayText.value = _shouldProcessImage
          ? _kStatusAnalyzing
          : _kStatusStopped;
    } catch (e) {
      debugPrint('[CameraScreen] Model warmup error: $e');
      _setError('โหลดโมเดล AI ไม่สำเร็จ');
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
    _translateDescription.dispose();
    _sequenceFrameBuffer.clear();

    final old = _controller;
    _controller = null;
    _isInitialized = false;

    if (old != null) {
      // Avoid dispose race during engine teardown (can trigger channel-error logs).
      unawaited(
        old.dispose().catchError((_) {
          // Ignore teardown-time platform channel errors.
        }),
      );
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
      _setError('เริ่มต้นกล้องไม่สำเร็จ');
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
    _sequenceFrameBuffer.clear();
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

    final frameTimestamp = _latestFrameTimestamp;
    if (frameTimestamp <= _lastProcessedTimestamp) return;
    _lastProcessedTimestamp = frameTimestamp;

    _isProcessingFrame = true;

    try {
      final img = _latestFrame!;
      final rotation = widget.cameras[_currentCameraIndex].sensorOrientation;
      final jpegBytes = await _inference.yuvToJpeg(img, rotation);
      final inferenceImageBytes = _buildSequenceInferenceImage(jpegBytes);
      const prompt = AppConfig.safetyPrompt;

      final inferenceStartMs = DateTime.now().millisecondsSinceEpoch;
      final sayRaw = await _inference.describeJpegBytesWithPrompt(
        inferenceImageBytes,
        prompt: prompt,
        maxNewTokens: AppConfig.maxNewTokens,
        temperature: 0.5,
      );
      final inferenceLatencyMs =
          DateTime.now().millisecondsSinceEpoch - inferenceStartMs;
      debugPrint('[Inference] latency=${inferenceLatencyMs}ms');
      if (_isDisposed || !_shouldProcessImage) return;
      final resultLagMs = _latestFrameTimestamp - frameTimestamp;
      if (resultLagMs > _maxAcceptableResultLagMs) {
        debugPrint(
          '[Inference] stale result dropped lag=${resultLagMs}ms '
          'ts=$frameTimestamp latest=$_latestFrameTimestamp',
        );
        return;
      }

      _consecutiveErrors = 0;

      final rawSelected = _selectPriorityCandidateFromRaw(sayRaw);
      final translated = await _translateDescription.execute(
        rawSelected.message,
        enabled: _translateToThai,
      );
      final cleanedTranslated = _cleanFinalOutputSentence(translated);
      if (cleanedTranslated.isEmpty) {
        _displayText.value = AppConfig.fallbackText;
        return;
      }

      final tagged = _extractTaggedPriority(cleanedTranslated);
      final say = tagged.message;
      if (say.isEmpty) {
        _displayText.value = AppConfig.fallbackText;
        return;
      }

      final decision = _speech.evaluate(say);
      // Do not trust raw pre-translation tags because models may echo prompt
      // examples/instructions with misleading [CRITICAL] labels.
      final effectivePriority = tagged.priority ?? decision.priority;
      final isCritical = effectivePriority == HazardPriority.critical;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (!isCritical && _isStableSceneDuplicate(say, nowMs)) {
        return;
      }
      _recordShownDescription(say, nowMs);

      _displayText.value = say;
      if (!_isTtsEnabled) {
        return;
      }

      debugPrint(
        '[TTS_GATE] decision allow=${decision.allowSpeak} '
        'critical=$isCritical priority=$effectivePriority text="$say"',
      );

      if (!decision.allowSpeak || effectivePriority == HazardPriority.clear) {
        return;
      }

      final speakDecision = _speakPolicy.decide(
        description: say,
        isCritical: isCritical,
      );
      debugPrint(
        '[TTS_GATE] policy shouldSpeak=${speakDecision.shouldSpeak} '
        'critical=$isCritical text="${speakDecision.text}"',
      );
      if (!speakDecision.shouldSpeak) return;
      _triggerVibration(isCritical);

      unawaited(
        _speech.speak(
          speakDecision.text,
          isCritical: isCritical,
          ttsEnabled: _isTtsEnabled,
        ),
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

  bool _isStableSceneDuplicate(String message, int nowMs) {
    final prev = _lastSpokenOrShownDescription;
    if (prev == null || _lastSpokenOrShownAtMs == 0) return false;
    if (nowMs - _lastSpokenOrShownAtMs > _sameSceneCooldownMs) return false;
    return _isDescriptionSimilar(prev, message);
  }

  void _recordShownDescription(String message, int nowMs) {
    _lastSpokenOrShownDescription = message;
    _lastSpokenOrShownAtMs = nowMs;
  }

  bool _isDescriptionSimilar(String a, String b) {
    final left = _normalizeDescKey(a);
    final right = _normalizeDescKey(b);
    if (left.isEmpty || right.isEmpty) return false;
    if (left == right) return true;

    final shorterLen = left.length < right.length ? left.length : right.length;
    if (shorterLen >= 16 && (left.contains(right) || right.contains(left))) {
      return true;
    }

    return false;
  }

  String _normalizeDescKey(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'^\s*\[(critical|awareness|clear)\]\s*'), '')
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]+', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _cleanFinalOutputSentence(String text) {
    var out = text.trim();
    if (out.isEmpty) return out;

    out = out.replaceAll(RegExp(r'''^["“”']+|["“”']+$'''), '');
    out = out.replaceAll(RegExp(r'"{2,}$'), '');
    out = out.replaceAll(RegExp(r'''(["“”']){2,}'''), '"');

    // Drop translated/echoed instruction tails like "- If dark" / "- ถ้ามืด".
    out = out.replaceAll(
      RegExp(
        r'\s*[-–—]\s*(if\s*(dark|unclear)|ถ้ามืด|หากมืด|ถ้าไม่ชัดเจน|หากไม่ชัดเจน).*$',
        caseSensitive: false,
      ),
      '',
    );

    // Keep exactly one sentence after translation cleanup.
    final m = RegExp(r'''^(.+?[.!?]['"]?)(?:\s|$)''').firstMatch(out);
    if (m != null) {
      out = (m.group(1) ?? '').trim();
    }

    out = out.replaceAll(RegExp(r'''["“”']+$'''), '');

    return out.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  _TaggedPriorityResult _extractTaggedPriority(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const _TaggedPriorityResult(message: '', priority: null);
    }

    final m = RegExp(
      r'^\s*\[(CRITICAL|AWARENESS|CLEAR)\]\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (m == null) {
      return _TaggedPriorityResult(message: trimmed, priority: null);
    }

    final tag = (m.group(1) ?? '').toUpperCase();
    final rest = (m.group(2) ?? '').trim();
    final priority = switch (tag) {
      'CRITICAL' => HazardPriority.critical,
      'AWARENESS' => HazardPriority.awareness,
      'CLEAR' => HazardPriority.clear,
      _ => null,
    };

    return _TaggedPriorityResult(
      message: rest.isEmpty ? trimmed : rest,
      priority: priority,
    );
  }

  _TaggedPriorityResult _selectPriorityCandidateFromRaw(String rawText) {
    final text = rawText.trim();
    if (text.isEmpty) {
      return const _TaggedPriorityResult(message: '', priority: null);
    }

    final lines = text
        .split('\n')
        .map((e) => e.trim())
        .where(
          (e) =>
              e.isNotEmpty &&
              !RegExp(
                r'^[-*]?\s*if\s+(unclear|dark|traffic)\b',
                caseSensitive: false,
              ).hasMatch(e),
        )
        .toList();

    final taggedLines = <_TaggedPriorityResult>[];
    _TaggedPriorityResult? firstUntagged;

    for (final line in lines) {
      final parsed = _extractTaggedPriority(line);
      if (parsed.priority != null) {
        taggedLines.add(parsed);
      } else {
        firstUntagged ??= parsed;
      }
    }

    for (final p in const <HazardPriority>[
      HazardPriority.critical,
      HazardPriority.awareness,
      HazardPriority.clear,
    ]) {
      for (final c in taggedLines) {
        if (c.priority == p && c.message.trim().isNotEmpty) {
          return c;
        }
      }
    }

    if (firstUntagged != null && firstUntagged.message.trim().isNotEmpty) {
      return firstUntagged;
    }

    return _extractTaggedPriority(text);
  }

  //รวมเฟรม
  Uint8List _buildSequenceInferenceImage(Uint8List currentJpeg) {
    if (!AppConfig.useSequenceInference || AppConfig.sequenceFrameCount <= 1) {
      return currentJpeg;
    }

    _sequenceFrameBuffer.add(currentJpeg);
    final maxFrames = AppConfig.sequenceFrameCount;
    if (_sequenceFrameBuffer.length > maxFrames) {
      _sequenceFrameBuffer.removeRange(
        0,
        _sequenceFrameBuffer.length - maxFrames,
      );
    }

    final combined = SequenceImageUtils.composeHorizontalStrip(
      _sequenceFrameBuffer,
    );
    if (combined.isEmpty) return currentJpeg;
    return combined;
  }

  void _triggerVibration(bool isCritical) {
    if (!_isVibrationEnabled) return;
    if (isCritical) {
      unawaited(HapticFeedback.heavyImpact());
      return;
    }
    unawaited(HapticFeedback.mediumImpact());
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

    _displayText.value = 'กำลังสลับกล้อง...';
    _announceUiAction('กำลังสลับกล้อง');
    _shouldProcessImage = false;

    try {
      _stopProcessingTimer();
      await _speech.stop();
      await _waitForOngoingFrameProcessing();

      // New camera = new scene: clear sequence buffer and dedup memory so the
      // first result from the switched camera is always fresh.
      _sequenceFrameBuffer.clear();
      _lastSpokenOrShownDescription = null;
      _lastSpokenOrShownAtMs = 0;

      final newIndex = (_currentCameraIndex + 1) % widget.cameras.length;
      await _ensureCameraInitialized(newIndex);

      _shouldProcessImage = true;
      _startProcessingTimer();
      _displayText.value = _kStatusAnalyzing;
      _announceUiAction('สลับกล้องสำเร็จ');
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
    _announceUiAction(
      newMode == FlashMode.torch ? 'เปิดไฟแฟลชแล้ว' : 'ปิดไฟแฟลชแล้ว',
    );
  }

  void _toggleProcessing() {
    if (_isDisposed) return;

    setState(() => _shouldProcessImage = !_shouldProcessImage);

    if (_shouldProcessImage) {
      // Clear stale sequence frames so old visual context from before the
      // pause does not bleed into the first inference after restart.
      _sequenceFrameBuffer.clear();
      // Reset dedup memory so the first new result is always spoken.
      _lastSpokenOrShownDescription = null;
      _lastSpokenOrShownAtMs = 0;

      _displayText.value = _kStatusAnalyzing;
      _startProcessingTimer();
      _announceUiAction('เริ่มการวิเคราะห์แล้ว');
    } else {
      _displayText.value = _kStatusStopped;
      _stopProcessingTimer();
      _speech.stop();
      _announceUiAction('หยุดการวิเคราะห์แล้ว');
    }
  }

  void _toggleTts() {
    if (_isDisposed) return;

    setState(() => _isTtsEnabled = !_isTtsEnabled);
    _saveSpeechPref(_isTtsEnabled);

    if (_isTtsEnabled) {
      _announceUiAction('เปิดเสียงพูดแล้ว');
    } else {
      _speech.stop();
      unawaited(HapticFeedback.mediumImpact());
    }
  }

  void _announceUiAction(String text) {
    if (!_isTtsEnabled || _isDisposed) return;
    unawaited(
      _speech.speak(text, isCritical: false, ttsEnabled: _isTtsEnabled),
    );
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
            size: _kBlindControlSize,
            iconSize: _kBlindIconSize,
            semanticLabel: 'ตั้งค่า',
            semanticHint: 'แตะเพื่อเปิดหน้าการตั้งค่า',
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleButton(
                icon: _desiredFlashMode == FlashMode.torch
                    ? Icons.flash_on
                    : Icons.flash_off,
                onTap: () => unawaited(_toggleFlash()),
                size: _kBlindControlSize,
                iconSize: _kBlindIconSize,
                color: _desiredFlashMode == FlashMode.torch
                    ? Colors.yellow
                    : Colors.white,
                selected: _desiredFlashMode == FlashMode.torch,
                semanticLabel: _desiredFlashMode == FlashMode.torch
                    ? 'ไฟแฟลช เปิดอยู่'
                    : 'ไฟแฟลช ปิดอยู่',
                semanticHint: 'แตะเพื่อเปิดหรือปิดไฟแฟลช',
              ),
            ],
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
            CircleButton(
              icon: _isTtsEnabled ? Icons.volume_up : Icons.volume_off,
              onTap: _toggleTts,
              size: _kBlindControlSize,
              iconSize: _kBlindIconSize,
              color: _isTtsEnabled ? Colors.white : Colors.white54,
              selected: _isTtsEnabled,
              semanticLabel: _isTtsEnabled
                  ? 'เสียงพูด เปิดอยู่'
                  : 'เสียงพูด ปิดอยู่',
              semanticHint: 'แตะเพื่อเปิดหรือปิดเสียงพูด',
            ),
            _buildStartStopButton(),
            if (widget.cameras.length > 1)
              CircleButton(
                icon: Icons.flip_camera_ios,
                onTap: () {
                  if (_isSwitchingCamera) return;
                  unawaited(_switchCamera());
                },
                size: _kBlindControlSize,
                iconSize: _kBlindIconSize,
                color: _isSwitchingCamera ? Colors.white54 : Colors.white,
                semanticLabel: 'สลับกล้อง',
                semanticHint: 'แตะเพื่อสลับกล้องหน้าและหลัง',
              )
            else
              const SizedBox(width: _kBlindControlSize),
          ],
        ),
      ),
    );
  }

  Widget _buildStartStopButton() {
    return Semantics(
      button: true,
      selected: _shouldProcessImage,
      label: _shouldProcessImage
          ? 'กำลังวิเคราะห์ แตะเพื่อหยุด'
          : 'หยุดการวิเคราะห์ แตะเพื่อเริ่ม',
      hint: 'ปุ่มหลักสำหรับควบคุมการวิเคราะห์ภาพ',
      child: GestureDetector(
        onTap: _toggleProcessing,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
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
                size: 28,
              ),
              const SizedBox(width: 10),
              Text(
                _shouldProcessImage ? 'หยุด' : 'เริ่ม',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
            ],
          ),
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
              _errorMessage ?? 'เกิดข้อผิดพลาดที่ไม่ทราบสาเหตุ',
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
              'ต้องอนุญาตการเข้าถึงกล้อง',
              style: TextStyle(color: Colors.white, fontSize: 20),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: openAppSettings,
              icon: const Icon(Icons.settings),
              label: const Text('เปิดการตั้งค่า'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaggedPriorityResult {
  final String message;
  final HazardPriority? priority;

  const _TaggedPriorityResult({required this.message, required this.priority});
}
