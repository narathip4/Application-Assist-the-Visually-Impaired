// lib/services/vlm/fast_vlm_service.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' as http_parser;

class FastVlmService {
  final String baseUrl;
  final Duration timeout;
  final http.Client _client;
  late final String _normalizedBase;

  // Compile regexes once for performance
  static final _sentenceSplitRegex = RegExp(r'(?<=[.!?])\s+');
  static final _whitespaceRegex = RegExp(r'\s+');
  static final _refusalRegex = RegExp(
    r"(i('?m)? sorry|cannot|can't|unable|policy|assist with this task)",
    caseSensitive: false,
  );

  FastVlmService(this.baseUrl, {required this.timeout, http.Client? client})
    : _client = client ?? http.Client() {
    _normalizedBase = baseUrl.replaceAll(RegExp(r'/$'), '');
  }

  /// Verify Space is alive
  Future<void> ensureInitialized() async {
    final uri = Uri.parse('$_normalizedBase/health');

    try {
      final resp = await _client.get(uri).timeout(timeout);
      if (resp.statusCode != 200) {
        throw Exception(
          'VLM health check failed ${resp.statusCode}: ${resp.body}',
        );
      }
    } catch (e) {
      throw Exception('VLM health check error: $e');
    }
  }

  /// Main API: send JPEG bytes -> get ONE short sentence with retry logic
  Future<String> describeJpegBytes(
    Uint8List jpegBytes, {
    required String prompt,
    int maxNewTokens = 24,
    int maxRetries = 2,
  }) async {
    int attempt = 0;
    Exception? lastError;

    while (attempt <= maxRetries) {
      try {
        return await _performInference(
          jpegBytes,
          prompt: prompt,
          maxNewTokens: maxNewTokens,
        );
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        attempt++;

        // Exponential backoff for retries
        if (attempt <= maxRetries) {
          await Future.delayed(Duration(milliseconds: 300 * attempt));
        }
      }
    }

    throw lastError ?? Exception('Unknown inference error');
  }

  Future<String> _performInference(
    Uint8List jpegBytes, {
    required String prompt,
    required int maxNewTokens,
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

    final streamed = await req.send().timeout(timeout);
    final body = await streamed.stream.bytesToString().timeout(timeout);

    // Debug: ดูว่าจริง ๆ server ส่งอะไรมา
    // ignore: avoid_print
    print(
      '[VLM] status=${streamed.statusCode} body=${body.length > 300 ? body.substring(0, 300) : body}',
    );

    if (streamed.statusCode != 200) {
      throw Exception('VLM API error ${streamed.statusCode}: $body');
    }

    final decoded = jsonDecode(body);

    // รองรับหลายรูปแบบ payload
    String raw = '';
    if (decoded is Map<String, dynamic>) {
      raw =
          (decoded['text'] as String?) ??
          (decoded['result'] as String?) ??
          (decoded['caption'] as String?) ??
          (decoded['output'] as String?) ??
          '';
      // บางระบบส่งเป็น { "choices":[{"text":"..."}] }
      if (raw.isEmpty && decoded['choices'] is List) {
        final choices = decoded['choices'] as List;
        if (choices.isNotEmpty && choices.first is Map) {
          raw = ((choices.first as Map)['text'] as String?) ?? '';
        }
      }
    } else if (decoded is String) {
      raw = decoded;
    }

    return _cleanOutput(raw);
  }

String _cleanOutput(String text) {
  if (text.trim().isEmpty) return 'Clear ahead.';

  final normalized =
      text.trim().replaceAll(RegExp(r'\s+'), ' ');

  // แยกเป็นประโยค
  final sentences =
      normalized.split(RegExp(r'(?<=[.!?])\s+'));

  // regex สำหรับ refusal (เฉพาะประโยคที่ขึ้นต้น)
  final refusal = RegExp(
    r"^(i(?:'m)?\s*sorry|sorry|i\s*cannot|i\s*can'?t|unable\s*to)\b",
    caseSensitive: false,
  );

  // หา “ประโยคแรกที่ไม่ใช่ refusal”
  for (final s in sentences) {
    final t = s.trim();
    if (t.isEmpty) continue;
    if (!refusal.hasMatch(t)) {
      return t;
    }
  }

  // ถ้าทุกประโยคเป็น refusal จริง ๆ
  return 'Clear ahead.';
}

}
