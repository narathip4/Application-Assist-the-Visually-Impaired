// lib/services/vlm/fast_vlm_service.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/app/config.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' as http_parser;

class VlmResponse {
  final String say;
  VlmResponse({required this.say});

  String get displayText => say;
}

class FastVlmService {
  final String baseUrl;
  final Duration timeout;
  final http.Client _client;
  late final String _normalizedBase;
  String? _lastSanitizedKey;
  int _lastSanitizedAtMs = 0;
  int _sameSanitizedCount = 0;

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
    r"(too dark|low light|poor lighting|underexposed|dark scene|dim)",
    caseSensitive: false,
  );
  static final _trafficSceneRegex = RegExp(
    r"(road|street|intersection|crosswalk|lane|highway)",
    caseSensitive: false,
  );
  static final _trafficVehicleRegex = RegExp(
    r"(car|truck|bus|motorcycle|motorbike|vehicle)",
    caseSensitive: false,
  );
  static final _personRegex = RegExp(
    r"(person|people|man|woman|child|pedestrian|group)",
    caseSensitive: false,
  );
  static final _animalRegex = RegExp(
    r"(dog|cat|animal)",
    caseSensitive: false,
  );
  static final _definiteHazardObjectRegex = RegExp(
    r"(pole|bicycle|bike|obstacle|stairs|step|open door|low obstacle|drop[- ]?off)",
    caseSensitive: false,
  );
  static final _contextHazardObjectRegex = RegExp(
    r"(bench|glass|door)",
    caseSensitive: false,
  );
  static final _hazardCueRegex = RegExp(
    r"(approach|approaching|toward|towards|crossing|blocking|block|directly ahead|in your path|swinging|running)",
    caseSensitive: false,
  );
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

  FastVlmService(
    this.baseUrl, {
    required this.timeout,
    http.Client? client,
  }) : _client = client ?? http.Client() {
    _normalizedBase = baseUrl.replaceAll(RegExp(r'/$'), '');
  }

  Future<void> ensureInitialized() async {
    final uri = Uri.parse('$_normalizedBase/health');
    final resp = await _client.get(uri).timeout(timeout);
    if (resp.statusCode != 200) {
      throw Exception('VLM health check failed ${resp.statusCode}');
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
    double? temperature,
  }) async {
    final uri = Uri.parse('$_normalizedBase/infer');

    final req = http.MultipartRequest('POST', uri)
      ..fields['prompt'] = prompt
      ..fields['max_new_tokens'] = maxNewTokens.toString()
      ..fields['temperature'] =
          (temperature ?? 0.5).clamp(0.0, 1.0).toStringAsFixed(2)
      ..files.add(
        http.MultipartFile.fromBytes(
          'image',
          jpegBytes,
          filename: 'frame.jpg',
          contentType: http_parser.MediaType('image', 'jpeg'),
        ),
      );

    final streamed = await _client.send(req).timeout(timeout);
    final body = await streamed.stream.bytesToString().timeout(timeout);

    // debug (short)
    // ignore: avoid_print
    print(
      '[VLM] status=${streamed.statusCode} body=${body.length > 220 ? body.substring(0, 220) : body}',
    );

    if (streamed.statusCode != 200) {
      throw Exception('VLM API error ${streamed.statusCode}');
    }

    final decoded = jsonDecode(body);
    final text = _extractText(decoded);
    return VlmResponse(say: _sanitize(text));
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

  String _sanitize(String raw) {
    var text = raw.trim();
    text = text.replaceAll(RegExp(r'^[\-\*\d\.\)\s"]+'), '');
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    text = _stripPromptEchoSegments(text);

    // Some models echo template; keep last sentence-ish if too long
    if (text.length > 400) {
      text = text.substring(text.length - 400);
      text = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    }

    if (text.isEmpty) {
      return 'The image is unclear and difficult to understand.';
    }

    if (_refusalRegex.hasMatch(text)) {
      return 'The image is unclear and difficult to understand.';
    }

    // Keep one sentence only for clean TTS.
    text = _keepOneSentence(text);
    if (_assistantFillerRegex.hasMatch(text)) {
      text = _stripAssistantFiller(text);
      text = _keepOneSentence(text);
    }

    if (text.isEmpty) {
      return 'Image unclear, please scan again.';
    }

    // Strict fallback normalization.
    if (_unclearFallbackPrefixRegex.hasMatch(text) ||
        (_unclearRegex.hasMatch(text) && !RegExp(r"\bif unclear\b", caseSensitive: false).hasMatch(text))) {
      return 'Image unclear, please scan again.';
    }
    if (_darkFallbackPrefixRegex.hasMatch(text) ||
        (_darkRegex.hasMatch(text) && !RegExp(r"\bif dark\b", caseSensitive: false).hasMatch(text))) {
      return 'Image too dark, please move to a brighter area.';
    }
    if (_looksLikeTrafficScene(text)) {
      return 'Careful, traffic area detected ahead, stop and reorient.';
    }

    // Enforce practical hazard phrasing.
    final looksHazard =
        _hazardCueRegex.hasMatch(text) ||
        _personRegex.hasMatch(text) ||
        _animalRegex.hasMatch(text) ||
        _definiteHazardObjectRegex.hasMatch(text) ||
        (_contextHazardObjectRegex.hasMatch(text) &&
            _hazardCueRegex.hasMatch(text));
    if (looksHazard && !text.toLowerCase().startsWith('careful,')) {
      text = 'Careful, ${_decapFirst(text)}';
    }

    // Keep short for TTS readability.
    if (text.length > 180) text = text.substring(0, 180).trim();
    if (!RegExp(r'[.!?]$').hasMatch(text)) {
      text = '$text.';
    }

    return _stabilizeMotionClaim(text);
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

  String _stripPromptEchoSegments(String text) {
    var out = text;

    // Remove echoed instruction bullets from prompt templates.
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
    out = out.replaceAll(RegExp(r'\bexamples?\s*:\b', caseSensitive: false), ' ');
    out = out.replaceAll(RegExp(r'\s+'), ' ').trim();

    return out;
  }

  bool _looksLikeTrafficScene(String text) {
    final t = text.toLowerCase();

    // Treat explicit model assertion as traffic only when it is the core message.
    if (t.startsWith('careful, traffic area detected')) return true;

    // Require both road-scene and vehicle context to avoid false alarms.
    return _trafficSceneRegex.hasMatch(t) && _trafficVehicleRegex.hasMatch(t);
  }

  String _decapFirst(String text) {
    if (text.isEmpty) return text;
    return text[0].toLowerCase() + text.substring(1);
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
}
