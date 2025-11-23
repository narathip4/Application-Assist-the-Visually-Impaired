import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// Provides text <-> token ID mapping for ONNX models.
class TokenizerService {
  final Map<String, dynamic> _config;
  final Map<String, int> _vocab;
  final Map<int, String> _idToToken;
  final int bosId;
  final int eosId;

  TokenizerService._(
    this._config,
    this._vocab,
    this._idToToken,
    this.bosId,
    this.eosId,
  );

  /// Loads tokenizer.json from the local model directory.
  static Future<TokenizerService> fromFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('Tokenizer file not found', filePath);
    }

    final raw = jsonDecode(await file.readAsString());
    final model = raw['model'] as Map<String, dynamic>;
    final vocab = Map<String, int>.from(model['vocab'] as Map);
    final idToToken = {for (var e in vocab.entries) e.value: e.key};

    final specialTokens = raw['added_tokens'] as List?;
    int bos = vocab['<s>'] ?? 1;
    int eos = vocab['</s>'] ?? 2;

    // If tokenizer.json defines added special tokens explicitly, prefer them.
    if (specialTokens != null) {
      for (final tok in specialTokens) {
        final s = tok as Map<String, dynamic>;
        if (s['special'] == true) {
          if (s['content'] == '<s>') bos = s['id'];
          if (s['content'] == '</s>') eos = s['id'];
        }
      }
    }

    return TokenizerService._(raw, vocab, idToToken, bos, eos);
  }

  /// Converts plain text to a list of token IDs.
  List<int> encode(String text) {
    final tokens = _basicTokenize(text);
    return tokens.map((t) => _vocab[t] ?? _vocab['<unk>'] ?? 0).toList();
  }

  /// Converts a list of token IDs back to human-readable text.
  String decode(List<int> ids) {
    final sb = StringBuffer();
    for (final id in ids) {
      final tok = _idToToken[id];
      if (tok == null) continue;
      if (tok.startsWith('▁')) {
        sb.write(' ');
        sb.write(tok.substring(1));
      } else {
        sb.write(tok);
      }
    }
    return sb.toString().trim();
  }

  /// Basic whitespace tokenizer (fallback if BPE rules absent).
  List<String> _basicTokenize(String text) {
    final norm = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (norm.isEmpty) return [];
    final parts = norm.split(' ');
    // Add ▁ prefix to simulate SentencePiece behavior.
    return parts.map((t) => '▁$t').toList();
  }
}
