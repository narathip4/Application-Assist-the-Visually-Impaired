import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ModelLoader {
  static const String _repo = 'onnx-community/FastVLM-0.5B-ONNX';
  static const String _base = 'https://huggingface.co';

  /// FP16 model + config files
  static const Map<String, String> _fp16 = {
    // ONNX models - FIXED URLs
    'vision_encoder_fp16.onnx':
        '$_base/$_repo/resolve/main/onnx/vision_encoder_fp16.onnx',
    'embed_tokens_fp16.onnx':
        '$_base/$_repo/resolve/main/onnx/embed_tokens_fp16.onnx',
    'decoder_model_merged_fp16.onnx':
        '$_base/$_repo/resolve/main/onnx/decoder_model_merged_fp16.onnx',

    // Tokenizer + configs - FIXED URLs
    'tokenizer.json': '$_base/$_repo/resolve/main/tokenizer.json',
    'preprocessor_config.json':
        '$_base/$_repo/resolve/main/preprocessor_config.json',
    'special_tokens_map.json':
        '$_base/$_repo/resolve/main/special_tokens_map.json',
    'generation_config.json':
        '$_base/$_repo/resolve/main/generation_config.json',
    'tokenizer_config.json': '$_base/$_repo/resolve/main/tokenizer_config.json',
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
    _log('Model directory: ${dir.path}');
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
      _log('Cached $name (${_mb(await file.length())} MB)');
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
    _log('Cached $name (${_mb(await file.length())} MB)');
  }

  static Future<bool> _isValid(String name, File f) async {
    try {
      if (!await f.exists()) {
        _log('$name: File does not exist');
        return false;
      }

      final bytes = await f.length();
      _log('Validating $name: ${_mb(bytes)} MB');

      // Check minimum size
      final minMB = _minSizeMB[name];
      if (minMB != null && bytes < minMB * 1024 * 1024) {
        _log('$name: Too small (${_mb(bytes)} MB < ${minMB} MB)');
        return false;
      }

      // Must have some content
      if (bytes == 0) {
        _log('$name: File is empty');
        return false;
      }

      // Read first bytes to detect HTML/error pages
      final raf = await f.open();
      final n = await raf.length();
      final head = await raf.read(n >= 1024 ? 1024 : n);
      await raf.close();

      final s = String.fromCharCodes(head);

      // Log first 200 chars for debugging
      _log(
        'First bytes of $name: ${s.substring(0, s.length > 200 ? 200 : s.length)}',
      );

      // Reject HTML/error content
      if (s.contains('<!DOCTYPE') ||
          s.contains('<html') ||
          s.contains('<HTML') ||
          s.contains('Cloudflare') ||
          s.contains('404') ||
          s.contains('403')) {
        _log('$name: Contains HTML/error content');
        return false;
      }

      // For ONNX files, just check it's binary (not text)
      if (name.endsWith('.onnx')) {
        // Check if it starts with printable ASCII (likely text/HTML)
        final firstChars = head.take(100).toList();
        int printableCount = 0;
        for (var byte in firstChars) {
          if (byte >= 32 && byte <= 126) printableCount++;
        }

        // If more than 80% printable ASCII, it's probably HTML/text
        if (printableCount > 80) {
          _log('$name: Appears to be text, not binary ONNX');
          return false;
        }

        _log('$name: Looks like binary ONNX file');
      }

      return bytes > 0;
    } catch (e) {
      _log('Validation error for $name: $e');
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

      _log('Downloading $name (attempt $i/$maxRetries)...');
      _log('URL: $url');

      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(url))
          ..followRedirects = true
          ..headers.addAll({
            'User-Agent': 'Mozilla/5.0 (compatible; FlutterApp/1.0)',
            'Accept': '*/*',
          });

        final resp = await client
            .send(req)
            .timeout(const Duration(minutes: 20));

        _log('HTTP Status: ${resp.statusCode}');
        _log('Content-Type: ${resp.headers['content-type']}');
        _log('Content-Length: ${resp.headers['content-length']}');

        if (resp.statusCode != 200) {
          await resp.stream.drain();
          throw HttpException('HTTP ${resp.statusCode}');
        }

        final sink = tmp.openWrite();
        int downloaded = 0;
        await for (var chunk in resp.stream) {
          sink.add(chunk);
          downloaded += chunk.length;
          if (downloaded % (10 * 1024 * 1024) == 0) {
            _log('   Downloaded: ${_mb(downloaded)} MB...');
          }
        }
        await sink.close();

        _log('Download complete: ${_mb(await tmp.length())} MB');

        final ct = (resp.headers['content-type'] ?? '').toLowerCase();
        if (ct.contains('text/html')) {
          throw const HttpException('Got HTML instead of binary');
        }

        await tmp.rename(dest.path);

        if (await _isValid(name, dest)) {
          _log('Validation passed for $name');
          return; // success
        }

        throw const HttpException('Post-download validation failed');
      } catch (e) {
        _log('Download error for $name: $e');
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

  /// Delete all cached models to force fresh download
  // static Future<void> clearCache() async {
  //   final dir = await _targetDir();
  //   if (await dir.exists()) {
  //     await dir.delete(recursive: true);
  //     _log('Cache cleared');
  //   }
  // }
}
