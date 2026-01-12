import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' as http_parser;

class FastVlmService {
  final String baseUrl; // e.g. https://username-space.hf.space
  final Duration timeout;
  final http.Client _client;

  FastVlmService(
    this.baseUrl, {
    required this.timeout,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Optional but recommended: verify Space is alive
  Future<void> ensureInitialized() async {
    final base = _normalizeBase(baseUrl);
    final uri = Uri.parse('$base/health');

    final resp = await _client.get(uri).timeout(timeout);
    if (resp.statusCode != 200) {
      throw Exception(
        'VLM health check failed ${resp.statusCode}: ${resp.body}',
      );
    }
  }

  /// Main API: send JPEG bytes -> get ONE short sentence
  Future<String> describeJpegBytes(
    Uint8List jpegBytes, {
    required String prompt,
    int maxNewTokens = 24,
  }) async {
    final base = _normalizeBase(baseUrl);
    final uri = Uri.parse('$base/infer');

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

    if (streamed.statusCode != 200) {
      throw Exception('VLM API error ${streamed.statusCode}: $body');
    }

    final json = jsonDecode(body) as Map<String, dynamic>;
    final raw = (json['text'] as String?) ?? '';

    return _cleanOutput(raw);
  }

  // ---------------- helpers ----------------

  String _normalizeBase(String url) {
    return url.replaceAll(RegExp(r'/$'), '');
  }

  /// Remove refusals, keep ONE sentence, always return something usable
  String _cleanOutput(String text) {
    final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final lower = t.toLowerCase();

    final refusal = RegExp(
      r"(i('?m)? sorry|cannot|can't|unable|policy|assist with this task)",
    );

    if (refusal.hasMatch(lower)) {
      return 'Clear ahead.';
    }

    // keep first sentence only
    final parts = t.split(RegExp(r'(?<=[.!?])\s+'));
    final first = parts.isNotEmpty ? parts.first.trim() : '';

    return first.isNotEmpty ? first : 'Clear ahead.';
  }

  void dispose() {
    _client.close();
  }
}
