// lib/services/vlm/fast_vlm_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/app/config.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' as http_parser;

class VlmResponse {
  final String say;
  VlmResponse({required this.say});

  String get displayText => say;
}

class VlmRequestException implements Exception {
  final String userMessage;
  final bool retryable;

  const VlmRequestException(this.userMessage, {this.retryable = false});

  @override
  String toString() => userMessage;
}

class _HttpResponseData {
  final int statusCode;
  final String body;

  const _HttpResponseData({required this.statusCode, required this.body});
}

class FastVlmService {
  final String baseUrl;
  final Duration timeout;
  final http.Client _client;
  late final String _normalizedBase;
  String? _lastSanitizedKey;
  int _lastSanitizedAtMs = 0;
  int _sameSanitizedCount = 0;

  static const int _maxRetryAttempts = 3;
  static const Duration _preflightTimeout = Duration(seconds: 2);
  static const Duration _healthTimeout = Duration(seconds: 6);

  static final _refusalRegex = RegExp(
    r"(i('?m)? sorry|cannot|can't|unable|policy|apologize)",
    caseSensitive: false,
  );
  static final _assistantFillerRegex = RegExp(
    r"(i hope this helps|let me know|anything else|how can i help|happy to help)",
    caseSensitive: false,
  );
  static final _unclearRegex = RegExp(
    r"(unclear|blurry|not clear|cannot see|can't see|insufficient|hard to understand|image quality)",
    caseSensitive: false,
  );
  static final _darkRegex = RegExp(
    r"(too dark|low light|poor lighting|underexposed|dark scene|dim|dark area)",
    caseSensitive: false,
  );
  static final _visibilityUncertainRegex = RegExp(
    r"(cannot confirm|can't confirm|not clearly visible|hard to see|obscures|obscure|unable to confirm|might be|could be|potential)",
    caseSensitive: false,
  );
  static final _clearPathRegex = RegExp(
    r"^(?:the\s+)?(?:path|walkway|way)(?:\s+ahead)?\s+(?:is\s+)?clear\.?$|^clear\s+path(?:\s+ahead)?\.?$|^(?:there\s+are\s+)?no\s+obstacles?\s+ahead\.?$|^nothing\s+(?:is\s+)?blocking\s+the\s+path\.?$",
    caseSensitive: false,
  );
  static final _hazardMentionRegex = RegExp(
    r"\b(person|people|pedestrian|car|truck|bus|motorcycle|bike|bicycle|vehicle|dog|cat|animal|stairs?|step|hole|pole|wall|door|glass|tree|cone|cart)\b",
    caseSensitive: false,
  );
  static final _trafficSceneRegex = RegExp(
    r"(road|street|intersection|crosswalk|lane|highway)",
    caseSensitive: false,
  );
  static final _trafficTopologyRegex = RegExp(
    r"(intersection|crosswalk|lane|highway)",
    caseSensitive: false,
  );
  static final _trafficVehicleRegex = RegExp(
    r"(car|truck|bus|motorcycle|motorbike|vehicle)",
    caseSensitive: false,
  );
  static final _stationaryVehicleRegex = RegExp(
    r"(parked|stationary|stopped|จอด)",
    caseSensitive: false,
  );
  static final _trafficMotionRegex = RegExp(
    r"(moving|approaching|driving|crossing|blocking|traffic)",
    caseSensitive: false,
  );
  static final _trafficObjectMatchers = <MapEntry<RegExp, String>>[
    MapEntry(RegExp(r'\bcrosswalk\b', caseSensitive: false), 'a crosswalk'),
    MapEntry(RegExp(r'\bintersection\b', caseSensitive: false), 'an intersection'),
    MapEntry(RegExp(r'\blane\b', caseSensitive: false), 'a traffic lane'),
    MapEntry(RegExp(r'\bhighway\b', caseSensitive: false), 'a highway'),
    MapEntry(RegExp(r'\bstreet\b', caseSensitive: false), 'a street'),
    MapEntry(RegExp(r'\broad\b', caseSensitive: false), 'a road'),
    MapEntry(RegExp(r'\bpickup truck\b', caseSensitive: false), 'a pickup truck'),
    MapEntry(RegExp(r'\btruck\b', caseSensitive: false), 'a truck'),
    MapEntry(RegExp(r'\bbus\b', caseSensitive: false), 'a bus'),
    MapEntry(RegExp(r'\bmotorcycle\b|\bmotorbike\b', caseSensitive: false), 'a motorcycle'),
    MapEntry(RegExp(r'\bbicycle\b|\bbike\b', caseSensitive: false), 'a bicycle'),
    MapEntry(RegExp(r'\bcars?\b', caseSensitive: false), 'cars'),
    MapEntry(RegExp(r'\bvehicles?\b', caseSensitive: false), 'vehicles'),
  ];
  static final _trafficPositionMatchers = <MapEntry<RegExp, String>>[
    MapEntry(
      RegExp(r'\b(on|to) the right\b|\bright side\b', caseSensitive: false),
      'on the right',
    ),
    MapEntry(
      RegExp(r'\b(on|to) the left\b|\bleft side\b', caseSensitive: false),
      'on the left',
    ),
    MapEntry(
      RegExp(r'\bin front\b|\bahead\b|\bin the distance\b', caseSensitive: false),
      'ahead',
    ),
    MapEntry(
      RegExp(r'\bnearby\b|\baround them\b|\baround\b', caseSensitive: false),
      'nearby',
    ),
  ];
  static final _strongMotionRegex = RegExp(
    r"(getting closer|approaching|toward you|towards you|walking toward|walking towards|running toward|running towards)",
    caseSensitive: false,
  );
  static final _unclearFallbackPrefixRegex = RegExp(
    r"^(image unclear|scene unclear|unable to see clearly)",
    caseSensitive: false,
  );
  static final _darkFallbackPrefixRegex = RegExp(
    r"^(image too dark|too dark|low light|poor lighting)",
    caseSensitive: false,
  );
  static final _responsePreambleRegex = RegExp(
    r'^(answer|response|output)\s*:\s*',
    caseSensitive: false,
  );
  static final _sceneLeadInRegex = RegExp(
    r'^(?:(?:the|this)\s+(?:image|scene|photo|picture|frame)\s+'
    r'(?:shows?|depicts?|displays?|contains?)\s+|'
    r'in\s+this\s+(?:image|scene|photo|picture|frame),?\s*|'
    r'the\s+most\s+important\s+nearby\s+(?:hazard|object)'
    r'(?:\s+in\s+this\s+scene)?\s+is\s+)',
    caseSensitive: false,
  );

  // Detects when the model echoes its own system-prompt text back.
  // Each sub-pattern is a phrase that only appears in our prompt, never in a
  // real scene description.  Two or more hits → treat as a prompt echo.
  static final _promptEchoSignals = <RegExp>[
    RegExp(r'you are a (real.?time|safety|visually)', caseSensitive: false),
    RegExp(r'return exactly one', caseSensitive: false),
    RegExp(r'focus only on (immediate|walking)', caseSensitive: false),
    RegExp(r'mention only the highest.?risk', caseSensitive: false),
    RegExp(r'no extra explanation', caseSensitive: false),
    RegExp(r'no chatbot', caseSensitive: false),
    RegExp(r'output one sentence only', caseSensitive: false),
    RegExp(r'real.?time safety assistant', caseSensitive: false),
    RegExp(r'visually impaired user', caseSensitive: false),
    RegExp(r'special cases\s*:', caseSensitive: false),
    RegExp(r'include one position word', caseSensitive: false),
    RegExp(r'use "careful,"', caseSensitive: false),
    RegExp(r'(never say|no polite phrases)', caseSensitive: false),
    RegExp(r'sensor output only', caseSensitive: false),
    RegExp(r'describe immediate walking safety', caseSensitive: false),
    RegExp(r'mention only the main hazard', caseSensitive: false),
    RegExp(r'path clear ahead', caseSensitive: false),
    RegExp(r'no distances', caseSensitive: false),
    RegExp(r'objects\s*:', caseSensitive: false),
    RegExp(r'states\s*:', caseSensitive: false),
    RegExp(r'positions\s*:', caseSensitive: false),
  ];

  FastVlmService(this.baseUrl, {required this.timeout, http.Client? client})
    : _client = client ?? http.Client() {
    _normalizedBase = baseUrl.replaceAll(RegExp(r'/$'), '');
  }

  Future<void> ensureInitialized() async {
    await _ensureHostResolvable();
    final uri = Uri.parse('$_normalizedBase/health');

    for (var attempt = 1; attempt <= _maxRetryAttempts; attempt++) {
      try {
        final resp = await _client.get(uri).timeout(_healthTimeout);
        if (resp.statusCode == 200) return;

        throw _mapStatusToException(
          resp.statusCode,
          defaultMessage: 'เซิร์ฟเวอร์โมเดลยังไม่พร้อมใช้งาน',
        );
      } on VlmRequestException catch (e) {
        if (!e.retryable || attempt == _maxRetryAttempts) rethrow;
      } on TimeoutException {
        if (attempt == _maxRetryAttempts) {
          throw const VlmRequestException(
            'เซิร์ฟเวอร์โมเดลใช้เวลาตอบสนองนานเกินไป',
            retryable: true,
          );
        }
      } on SocketException catch (_) {
        if (attempt == _maxRetryAttempts) {
          throw const VlmRequestException(
            'ไม่มีอินเทอร์เน็ตหรือไม่สามารถติดต่อเซิร์ฟเวอร์ได้',
            retryable: true,
          );
        }
      } on http.ClientException catch (_) {
        if (attempt == _maxRetryAttempts) {
          throw const VlmRequestException(
            'เชื่อมต่อเซิร์ฟเวอร์โมเดลไม่สำเร็จ',
            retryable: true,
          );
        }
      }

      await Future.delayed(_retryDelayForAttempt(attempt));
    }
  }

  /// Multipart because your HF server expects:
  /// image: UploadFile (File)
  /// prompt: Form
  /// max_new_tokens: Form
  Future<VlmResponse> describeJpegBytes(
    Uint8List jpegBytes, {
    required String prompt,
    int maxNewTokens = AppConfig.maxNewTokens,
  }) async {
    final uri = Uri.parse('$_normalizedBase/infer');

    for (var attempt = 1; attempt <= _maxRetryAttempts; attempt++) {
      try {
        final req = http.MultipartRequest('POST', uri)
          ..fields['prompt'] = prompt
          ..fields['max_new_tokens'] = maxNewTokens.toString()
          ..files.add(
            http.MultipartFile.fromBytes(
              'image',
              jpegBytes,
              filename: 'frame.jpg',
              contentType: http_parser.MediaType('image', 'jpeg'),
            ),
          );

        final response = await _sendMultipartWithinTimeout(req);

        _debugLog(
          '[VLM] status=${response.statusCode} body=${response.body.length > 140 ? response.body.substring(0, 140) : response.body}',
        );

        if (response.statusCode != 200) {
          throw _mapStatusToException(
            response.statusCode,
            defaultMessage: 'เซิร์ฟเวอร์โมเดลตอบกลับผิดปกติ',
          );
        }

        final decoded = jsonDecode(response.body);
        final text = _extractText(decoded);
        return VlmResponse(say: _sanitize(text));
      } on VlmRequestException catch (e) {
        if (!e.retryable || attempt == _maxRetryAttempts) rethrow;
      } on TimeoutException {
        if (attempt == _maxRetryAttempts) {
          throw const VlmRequestException(
            'เซิร์ฟเวอร์ใช้เวลาตอบสนองนานเกินไป',
            retryable: true,
          );
        }
      } on SocketException catch (_) {
        if (attempt == _maxRetryAttempts) {
          throw const VlmRequestException(
            'ไม่มีอินเทอร์เน็ตหรือไม่สามารถติดต่อเซิร์ฟเวอร์ได้',
            retryable: true,
          );
        }
      } on http.ClientException catch (_) {
        if (attempt == _maxRetryAttempts) {
          throw const VlmRequestException(
            'เชื่อมต่อเซิร์ฟเวอร์โมเดลไม่สำเร็จ',
            retryable: true,
          );
        }
      }

      await Future.delayed(_retryDelayForAttempt(attempt));
    }

    throw const VlmRequestException(
      'ไม่สามารถเรียกใช้โมเดลได้',
      retryable: true,
    );
  }

  Future<_HttpResponseData> _sendMultipartWithinTimeout(
    http.MultipartRequest request,
  ) async {
    return (() async {
      final streamed = await _client.send(request);
      final body = await streamed.stream.bytesToString();
      return _HttpResponseData(statusCode: streamed.statusCode, body: body);
    }()).timeout(timeout);
  }

  Future<void> _ensureHostResolvable() async {
    final host = Uri.parse(_normalizedBase).host;
    if (host.isEmpty) {
      throw const VlmRequestException('ตั้งค่า URL ของเซิร์ฟเวอร์ไม่ถูกต้อง');
    }

    try {
      final result = await InternetAddress.lookup(
        host,
      ).timeout(_preflightTimeout);
      if (result.isEmpty || result.every((e) => e.rawAddress.isEmpty)) {
        throw const SocketException('No host addresses found');
      }
    } on SocketException {
      throw const VlmRequestException(
        'ไม่มีอินเทอร์เน็ตหรือไม่สามารถติดต่อเซิร์ฟเวอร์ได้',
        retryable: true,
      );
    } on TimeoutException {
      throw const VlmRequestException(
        'ตรวจสอบการเชื่อมต่ออินเทอร์เน็ตไม่สำเร็จ',
        retryable: true,
      );
    }
  }

  Duration _retryDelayForAttempt(int attempt) {
    switch (attempt) {
      case 1:
        return const Duration(milliseconds: 1200);
      case 2:
        return const Duration(milliseconds: 2500);
      default:
        return const Duration(seconds: 4);
    }
  }

  VlmRequestException _mapStatusToException(
    int statusCode, {
    required String defaultMessage,
  }) {
    if (statusCode == 408 || statusCode == 425 || statusCode == 429) {
      return const VlmRequestException(
        'เซิร์ฟเวอร์กำลังยุ่ง โปรดลองอีกครั้ง',
        retryable: true,
      );
    }
    if (statusCode == 502 || statusCode == 503 || statusCode == 504) {
      return const VlmRequestException(
        'เซิร์ฟเวอร์โมเดลกำลังเริ่มทำงาน โปรดลองอีกครั้ง',
        retryable: true,
      );
    }
    if (statusCode >= 500) {
      return const VlmRequestException(
        'เซิร์ฟเวอร์โมเดลมีปัญหาชั่วคราว',
        retryable: true,
      );
    }
    return VlmRequestException(defaultMessage);
  }

  String _extractText(dynamic decoded) {
    if (decoded is Map<String, dynamic>) {
      String raw =
          (decoded['say'] as String?) ??
          (decoded['text'] as String?) ??
          (decoded['result'] as String?) ??
          (decoded['caption'] as String?) ??
          (decoded['output'] as String?) ??
          '';

      if (raw.isEmpty && decoded['choices'] is List) {
        final choices = decoded['choices'] as List;
        if (choices.isNotEmpty && choices.first is Map) {
          raw = ((choices.first as Map)['text'] as String?) ?? '';
        }
      }
      return raw;
    }
    if (decoded is String) return decoded;
    return '';
  }

  void _debugLog(String message) {
    if (kDebugMode) {
      debugPrint(message);
    }
  }

  /// Returns true if [text] looks like the model echoed back the system prompt.
  /// We require ≥2 independent signals so a single coincidental word doesn't
  /// suppress a real observation.
  bool _isSystemPromptEcho(String text) {
    int hits = 0;
    for (final pattern in _promptEchoSignals) {
      if (pattern.hasMatch(text)) {
        hits++;
        if (hits >= 2) return true;
      }
    }
    return false;
  }

  /// Returns true if [text] is a verbatim copy of one of the Special-Cases
  /// canned phrases baked into the prompt template.
  ///
  /// These exact phrases are legitimate model outputs because the prompt
  /// explicitly instructs the model to emit them for fallback cases.
  String? _normalizeVerbatimSpecialCase(String text) {
    final t = text.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
    switch (t) {
      case 'scene unclear, cannot confirm what is ahead.':
        return 'Scene unclear, cannot confirm what is ahead.';
      case 'too dark to see clearly.':
        return 'Too dark to see clearly.';
      case 'the path ahead is clear.':
        return 'The path ahead is clear.';
      case 'careful, traffic area detected.':
      case 'careful, traffic area detected ahead.':
        return 'Careful, traffic area ahead.';
    }
    return null;
  }

  String _sanitize(String raw) {
    var text = raw.trim();

    // ── Prompt-echo guard (check raw, before any stripping) ──────────────────
    // If the model simply repeated our system prompt or its Special Cases
    // lines, bail out immediately rather than letting a coincidental first
    // sentence slip through as a real observation.
    if (_isSystemPromptEcho(text)) {
      debugPrint('[VLM] prompt-echo detected (system prompt), dropping.');
      return '';
    }

    text = text.replaceAll(RegExp(r'^[\-\*\d\.\)\s"]+'), '');
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    text = _stripPromptEchoSegments(text);
    text = _stripResponsePreamble(text);

    // Some models echo template; keep last sentence-ish if too long
    if (text.length > 400) {
      text = text.substring(text.length - 400);
      text = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    }

    if (text.isEmpty) {
      debugPrint('[VLM] empty text response, dropping.');
      return '';
    }

    if (_refusalRegex.hasMatch(text)) {
      return 'Scene unclear, cannot confirm what is ahead.';
    }

    // Keep one sentence only for clean TTS.
    text = _keepOneSentence(text);
    if (_assistantFillerRegex.hasMatch(text)) {
      text = _stripAssistantFiller(text);
      text = _keepOneSentence(text);
    }
    text = _stripSceneLeadIn(text);

    if (text.isEmpty) {
      return 'Scene unclear, cannot confirm what is ahead.';
    }

    final specialCase = _normalizeVerbatimSpecialCase(text);
    if (specialCase != null) {
      return specialCase;
    }

    // Strict fallback normalization.
    if (_looksLikeDarkScene(text)) return 'Too dark to see clearly.';
    if (_looksLikeUnclearScene(text)) {
      return 'Scene unclear, cannot confirm what is ahead.';
    }
    if (_looksLikeClearPath(text)) return 'The path ahead is clear.';
    if (_looksLikeTrafficScene(text)) return _normalizeTrafficScene(text);

    // Keep short for TTS readability.
    if (text.length > 180) text = text.substring(0, 180).trim();
    if (!RegExp(r'[.!?]$').hasMatch(text)) {
      text = '$text.';
    }

    return _stabilizeMotionClaim(text);
  }

  bool _looksLikeDarkScene(String text) {
    final t = text.toLowerCase();
    if (_darkFallbackPrefixRegex.hasMatch(t)) return true;
    return _darkRegex.hasMatch(t) && _visibilityUncertainRegex.hasMatch(t);
  }

  bool _looksLikeUnclearScene(String text) {
    final t = text.toLowerCase();
    if (_unclearFallbackPrefixRegex.hasMatch(t)) return true;
    return _unclearRegex.hasMatch(t) &&
        !RegExp(r"\bif unclear\b", caseSensitive: false).hasMatch(t);
  }

  bool _looksLikeClearPath(String text) {
    final t = text.toLowerCase();
    if (!_clearPathRegex.hasMatch(t)) return false;
    return !_hazardMentionRegex.hasMatch(t);
  }

  String _keepOneSentence(String text) {
    final m = RegExp(r'''^(.+?[.!?]['"]?)(?:\s|$)''').firstMatch(text);
    if (m != null) return (m.group(1) ?? '').trim();
    return text.trim();
  }

  String _stripAssistantFiller(String text) {
    return text
        .replaceAll(_assistantFillerRegex, '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _stripResponsePreamble(String text) {
    var out = text.trim();
    while (_responsePreambleRegex.hasMatch(out)) {
      out = out.replaceFirst(_responsePreambleRegex, '').trim();
    }
    return out;
  }

  String _stripSceneLeadIn(String text) {
    var out = text.trim();
    out = out.replaceFirst(_sceneLeadInRegex, '').trim();
    out = out.replaceAll(RegExp(r'\s+'), ' ');
    if (out.isEmpty) return text.trim();
    return '${out[0].toUpperCase()}${out.substring(1)}';
  }

  String _stripPromptEchoSegments(String text) {
    var out = text;

    // Remove echoed instruction bullets: "- If unclear: "..." "
    out = out.replaceAll(
      RegExp(
        r'(\-?\s*if\s+(unclear|dark|traffic)\s*:\s*"[^"]*"\s*)',
        caseSensitive: false,
      ),
      ' ',
    );
    out = out.replaceAll(
      RegExp(
        r'(\-?\s*if\s+(unclear|dark|traffic)\s*:\s*[^.]+\.?\s*)',
        caseSensitive: false,
      ),
      ' ',
    );

    // Remove prompt preamble/instructions if the model echoes them inline.
    out = out.replaceAll(
      RegExp(
        r'you are a real.?time safety assistant[^.]*\.',
        caseSensitive: false,
      ),
      ' ',
    );
    out = out.replaceAll(
      RegExp(r'return exactly one [^.]+\.', caseSensitive: false),
      ' ',
    );
    out = out.replaceAll(
      RegExp(r'focus only on [^.]+\.', caseSensitive: false),
      ' ',
    );
    out = out.replaceAll(
      RegExp(r'mention only the [^.]+\.', caseSensitive: false),
      ' ',
    );
    out = out.replaceAll(
      RegExp(r'sensor output only[^.]*\.', caseSensitive: false),
      ' ',
    );
    out = out.replaceAll(
      RegExp(r'describe immediate walking safety[^.]*\.', caseSensitive: false),
      ' ',
    );
    out = out.replaceAll(
      RegExp(r'mention only the main hazard[^.]*\.', caseSensitive: false),
      ' ',
    );
    out = out.replaceAll(
      RegExp(r'say "path clear ahead\." if [^.]+\.', caseSensitive: false),
      ' ',
    );
    out = out.replaceAll(
      RegExp(r'no distances[^.]*\.', caseSensitive: false),
      ' ',
    );
    out = out.replaceAll(
      RegExp(r'\bexamples?\s*:\b', caseSensitive: false),
      ' ',
    );
    out = out.replaceAll(
      RegExp(r'\bspecial cases\s*:\s*', caseSensitive: false),
      ' ',
    );
    out = out.replaceAll(
      RegExp(r'\b(objects|states|positions)\s*:[^.]*\.', caseSensitive: false),
      ' ',
    );

    // Strip trailing rule/bullet lines that sometimes appear after the real answer.
    out = out.replaceAll(
      RegExp(
        r'\s*[\-\*]\s*(use|include|mention|no |never |output one)[^\n]*',
        caseSensitive: false,
      ),
      '',
    );

    out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
    return out;
  }

  bool _looksLikeTrafficScene(String text) {
    final t = text.toLowerCase();

    // Treat explicit model assertion as traffic only when it is the core message.
    if (t.startsWith('careful, traffic area detected')) return true;

    if (_trafficTopologyRegex.hasMatch(t)) return true;

    // Simple mentions like "parked motorcycles on the right" plus "street"
    // should stay as natural scene descriptions, not traffic warnings.
    if (_stationaryVehicleRegex.hasMatch(t) && !_trafficMotionRegex.hasMatch(t)) {
      return false;
    }

    // Traffic warning only when a roadway/street context is paired with
    // vehicles that look active or traffic-related.
    return _trafficSceneRegex.hasMatch(t) &&
        _trafficVehicleRegex.hasMatch(t) &&
        _trafficMotionRegex.hasMatch(t);
  }

  String _normalizeTrafficScene(String text) {
    final trafficObject = _extractTrafficObject(text);
    final trafficPosition = _extractTrafficPosition(text);

    final objectPart = trafficObject ?? 'traffic';
    final positionPart = switch (trafficPosition) {
      'ahead' => ' ahead',
      'nearby' => ' nearby',
      final p? => ' $p',
      null => ' ahead',
    };

    return 'Careful, traffic area$positionPart with $objectPart.';
  }

  String? _extractTrafficObject(String text) {
    for (final entry in _trafficObjectMatchers) {
      if (entry.key.hasMatch(text)) return entry.value;
    }
    return null;
  }

  String? _extractTrafficPosition(String text) {
    for (final entry in _trafficPositionMatchers) {
      if (entry.key.hasMatch(text)) return entry.value;
    }
    return null;
  }

  String _stabilizeMotionClaim(String text) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final key = text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

    if (_lastSanitizedKey == key && nowMs - _lastSanitizedAtMs <= 10000) {
      _sameSanitizedCount++;
    } else {
      _sameSanitizedCount = 1;
    }
    _lastSanitizedKey = key;
    _lastSanitizedAtMs = nowMs;

    // If identical "approaching" sentence repeats many times in a static scene,
    // downgrade movement wording to avoid persistent false urgency.
    if (_sameSanitizedCount < 4 || !_strongMotionRegex.hasMatch(text)) {
      return text;
    }

    var downgraded = text;
    downgraded = downgraded.replaceAll(
      RegExp(r'getting closer', caseSensitive: false),
      'staying in place',
    );
    downgraded = downgraded.replaceAll(
      RegExp(r'approaching', caseSensitive: false),
      'stationary',
    );
    downgraded = downgraded.replaceAll(
      RegExp(r'toward(s)? you', caseSensitive: false),
      'ahead',
    );
    downgraded = downgraded.replaceAll(
      RegExp(r'walking toward(s)?', caseSensitive: false),
      'standing',
    );
    downgraded = downgraded.replaceAll(
      RegExp(r'running toward(s)?', caseSensitive: false),
      'standing',
    );
    downgraded = downgraded.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (!RegExp(r'[.!?]$').hasMatch(downgraded)) {
      downgraded = '$downgraded.';
    }
    return downgraded;
  }

  @visibleForTesting
  String sanitizeForTest(String raw) => _sanitize(raw);
}
