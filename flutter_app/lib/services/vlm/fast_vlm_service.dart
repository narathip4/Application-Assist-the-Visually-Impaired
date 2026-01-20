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

  static final _refusalRegex = RegExp(
    r"(i('?m)? sorry|cannot|can't|unable|policy|apologize)",
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
  }) async {
    final uri = Uri.parse('$_normalizedBase/infer');

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
    var text = raw.trim().replaceAll(RegExp(r'\s+'), ' ');

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

    // Keep short for TTS
    if (text.length > 300) text = text.substring(0, 300);

    return text;
  }
}
