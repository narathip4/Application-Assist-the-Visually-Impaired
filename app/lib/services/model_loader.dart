import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ModelLoader {
  static const String _repo = 'onnx-community/FastVLM-0.5B-ONNX';
  static const String _base = 'https://huggingface.co';

  /// FP16 model + config files
  static const Map<String, String> _fp16 = {
    // ONNX models
    'vision_encoder_fp16.onnx':
        '$_base/$_repo/resolve/main/onnx/vision_encoder_fp16.onnx?download=true',
    'embed_tokens_fp16.onnx':
        '$_base/$_repo/resolve/main/onnx/embed_tokens_fp16.onnx?download=true',
    'decoder_model_merged_fp16.onnx':
        '$_base/$_repo/resolve/main/onnx/decoder_model_merged_fp16.onnx?download=true',

    // Tokenizer + configs
    'tokenizer.json': '$_base/$_repo/resolve/main/tokenizer.json?download=true',
    'preprocessor_config.json':
        '$_base/$_repo/resolve/main/preprocessor_config.json?download=true',
    'special_tokens_map.json':
        '$_base/$_repo/resolve/main/special_tokens_map.json?download=true',
    'generation_config.json':
        '$_base/$_repo/resolve/main/generation_config.json?download=true',
    'tokenizer_config.json':
        '$_base/$_repo/resolve/main/tokenizer_config.json?download=true',
  };

  /// Minimum expected file sizes (MB)
  static const Map<String, int> _minSizeMB = {
    'vision_encoder_fp16.onnx': 220, // real ≈241 MB
    'embed_tokens_fp16.onnx': 0, // small but needed
    'decoder_model_merged_fp16.onnx': 50, // ≈54 MB
    'tokenizer.json': 8,
  };

  static const String _folder = 'models/FastVLM-0.5B-ONNX';

  /// Ensures all models and configs are present and valid.
  static Future<void> ensureModelsDownloaded() async {
    final dir = await _targetDir();
    if (!await dir.exists()) await dir.create(recursive: true);

    for (final e in _fp16.entries) {
      await _ensureOne(e.key, e.value);
    }
  }

  /// Returns all file paths.
  static Future<Map<String, String>> getAllModelPaths() async {
    final dir = await _targetDir();
    final out = <String, String>{};

    for (final name in _fp16.keys) {
      final f = File(p.join(dir.path, name));
      if (!await _isValid(name, f)) {
        throw FileSystemException('Model file not found or invalid', f.path);
      }
      out[name] = f.path;
    }
    return out;
  }

  /// Debug helper: print all cached files.
  static Future<void> printInventory() async {
    final dir = await _targetDir();
    _log('📂 Model directory: ${dir.path}');
    if (!await dir.exists()) return;

    final entries = await dir.list().where((e) => e is File).toList();
    entries.sort((a, b) => a.path.compareTo(b.path));

    for (final e in entries) {
      final len = await (e as File).length();
      _log(' - ${e.path} (${_mb(len)} MB)');
    }
  }

  static Future<Directory> _targetDir() async {
    final base = await getApplicationDocumentsDirectory();
    return Directory(p.join(base.path, _folder));
  }

  static Future<void> _ensureOne(String name, String url) async {
    final dir = await _targetDir();
    final file = File(p.join(dir.path, name));

    if (await _isValid(name, file)) {
      _log('√ Cached $name (${_mb(await file.length())} MB)');
      return;
    }

    await file.parent.create(recursive: true);
    await _downloadWithChecks(url, file, name);

    // Final validation
    if (!await _isValid(name, file)) {
      try {
        await file.delete();
      } catch (_) {}
      throw HttpException('Downloaded $name but validation failed.');
    }
    _log('√ Cached $name (${_mb(await file.length())} MB)');
  }

  static Future<bool> _isValid(String name, File f) async {
    try {
      if (!await f.exists()) return false;
      final bytes = await f.length();
      final minMB = _minSizeMB[name];
      if (minMB != null && bytes < minMB * 1024 * 1024) return false;

      // sanity: detect HTML pages instead of binary
      final raf = await f.open();
      final n = await raf.length();
      final head = await raf.read(n >= 512 ? 512 : n);
      await raf.close();
      final s = String.fromCharCodes(head);
      if (s.contains('<!DOCTYPE') ||
          s.contains('<html') ||
          s.contains('error') ||
          s.contains('Cloudflare'))
        return false;

      return bytes > 0;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _downloadWithChecks(
    String url,
    File dest,
    String name,
  ) async {
    const maxRetries = 4;

    for (int i = 1; i <= maxRetries; i++) {
      final tmp = File('${dest.path}.part');
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      try {
        if (await dest.exists()) await dest.delete();
      } catch (_) {}

      _log('⬇ Downloading $name (attempt $i/$maxRetries)...');

      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(url))
          ..followRedirects = true
          ..headers.addAll({
            'accept': 'application/octet-stream',
            'user-agent': 'flutter-app/onnx-downloader',
          });

        final resp = await client
            .send(req)
            .timeout(const Duration(minutes: 20));

        if (resp.statusCode != 200) {
          await resp.stream.drain();
          throw HttpException('HTTP ${resp.statusCode}');
        }

        final sink = tmp.openWrite();
        await resp.stream.listen(sink.add).asFuture();
        await sink.close();

        final ct = (resp.headers['content-type'] ?? '').toLowerCase();
        if (ct.contains('text/html')) {
          throw const HttpException('Got HTML instead of binary');
        }

        await tmp.rename(dest.path);

        if (await _isValid(name, dest)) return; // success
        throw const HttpException('Post-download validation failed');
      } catch (e) {
        _log('⚠️ Download error for $name: $e');
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
        await Future.delayed(Duration(milliseconds: 400 * i));
        if (i == maxRetries) rethrow;
      } finally {
        client.close();
      }
    }
  }

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(2);
  static void _log(Object o) => print(o);
}
