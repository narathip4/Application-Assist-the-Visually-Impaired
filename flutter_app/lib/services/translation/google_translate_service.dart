import 'dart:convert';

import 'package:http/http.dart' as http;

class GoogleTranslateService {
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;

  GoogleTranslateService({required this.timeout, http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  Future<String> translate({
    required String text,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    final source = sourceLanguage.trim().toLowerCase();
    final target = targetLanguage.trim().toLowerCase();
    if (text.trim().isEmpty || source.isEmpty || target.isEmpty) return text;
    if (source == target) return text;

    final uri = Uri.https('translate.googleapis.com', '/translate_a/single', {
      'client': 'gtx',
      'sl': source,
      'tl': target,
      'dt': 't',
      'q': text,
    });

    final resp = await _client.get(uri).timeout(timeout);
    if (resp.statusCode != 200) {
      throw Exception('Translate API error ${resp.statusCode}');
    }

    final decoded = jsonDecode(resp.body);
    final translated = _extractTranslatedText(decoded);
    if (translated.isEmpty) {
      throw Exception('Translate API returned empty text');
    }
    return translated;
  }

  String _extractTranslatedText(dynamic decoded) {
    if (decoded is! List || decoded.isEmpty) return '';
    final chunks = decoded.first;
    if (chunks is! List) return '';

    final out = StringBuffer();
    for (final chunk in chunks) {
      if (chunk is List && chunk.isNotEmpty && chunk.first is String) {
        out.write(chunk.first as String);
      }
    }
    return out.toString().trim();
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
