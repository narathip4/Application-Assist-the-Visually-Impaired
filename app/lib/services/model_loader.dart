import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Handles model file management for the FastVLM ONNX package.
///
/// This class is responsible for:
/// 1. Ensuring that all model and configuration files are downloaded.
/// 2. Verifying file validity and minimum size.
/// 3. Printing a local inventory for debugging purposes.
///
/// The downloaded models are stored under:
///   {application_documents_directory}/models/FastVLM-0.5B-ONNX
class ModelLoader {
  static const String _repo = 'onnx-community/FastVLM-0.5B-ONNX';
  static const String _base = 'https://huggingface.co';

  /// Mapping of model and configuration filenames to their Hugging Face URLs.
  static const Map<String, String> _fp32 = {
    // Core ONNX models
    'vision_encoder.onnx':
        '$_base/$_repo/resolve/main/onnx/vision_encoder.onnx',
    'embed_tokens.onnx': '$_base/$_repo/resolve/main/onnx/embed_tokens.onnx',
    'decoder_model_merged.onnx':
        'https://huggingface.co/onnx-community/FastVLM-0.5B-ONNX/resolve/main/onnx/decoder_model_merged.onnx?download=true',

    // Tokenizer and configuration files
    'tokenizer.json': '$_base/$_repo/resolve/main/tokenizer.json',
    'preprocessor_config.json':
        '$_base/$_repo/resolve/main/preprocessor_config.json',
    'special_tokens_map.json':
        '$_base/$_repo/resolve/main/special_tokens_map.json',
    'generation_config.json':
        '$_base/$_repo/resolve/main/generation_config.json',
    'tokenizer_config.json': '$_base/$_repo/resolve/main/tokenizer_config.json',
  };

  /// Minimum size thresholds (in megabytes) for model files.
  /// Used to detect incomplete or invalid downloads.
  static const Map<String, int> _minSizeMB = {
    'vision_encoder.onnx': 220,
    'embed_tokens.onnx': 1,
    'decoder_model_merged.onnx': 1,
    'tokenizer.json': 1,
  };

  /// Local model directory relative to app documents path.
  static const String _folder = 'models/FastVLM-0.5B-ONNX';

  /// Ensures all model and configuration files are downloaded and valid.
  static Future<void> ensureModelsDownloaded() async {
    final dir = await _targetDir();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    for (final entry in _fp32.entries) {
      await _ensureOne(entry.key, entry.value);
    }
  }

  /// Returns a map of model filenames to their absolute local paths.
  /// Throws [FileSystemException] if any required file is missing or invalid.
  static Future<Map<String, String>> getAllModelPaths() async {
    final dir = await _targetDir();
    final result = <String, String>{};

    for (final name in _fp32.keys) {
      final file = File(p.join(dir.path, name));
      if (!await _isValid(name, file)) {
        throw FileSystemException('Model file not found or invalid', file.path);
      }
      result[name] = file.path;
    }
    return result;
  }

  /// Prints all cached model files with their sizes for debugging.
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

  /// Resolves the target directory where model files are stored.
  static Future<Directory> _targetDir() async {
    final base = await getApplicationDocumentsDirectory();
    return Directory(p.join(base.path, _folder));
  }

  /// Ensures that a single model file exists and passes validation.
  /// If the file is missing or invalid, it will be downloaded again.
  static Future<void> _ensureOne(String name, String url) async {
    final dir = await _targetDir();
    final file = File(p.join(dir.path, name));

    if (await _isValid(name, file)) {
      _log('Cached $name (${_mb(await file.length())} MB)');
      return;
    }

    await file.parent.create(recursive: true);
    await _downloadWithChecks(url, file, name);

    if (!await _isValid(name, file)) {
      try {
        await file.delete();
      } catch (_) {}
      throw HttpException('Downloaded $name but validation failed.');
    }

    _log('Cached $name (${_mb(await file.length())} MB)');
  }

  /// Validates that a file exists, meets size requirements, and is not an HTML error page.
  static Future<bool> _isValid(String name, File file) async {
    try {
      if (!await file.exists()) return false;

      final bytes = await file.length();
      final minMB = _minSizeMB[name];
      if (minMB != null && bytes < minMB * 1024 * 1024) return false;
      if (bytes == 0) return false;

      final raf = await file.open();
      final n = await raf.length();
      final head = await raf.read(n >= 1024 ? 1024 : n);
      await raf.close();

      final sample = String.fromCharCodes(head);
      if (sample.contains('<!DOCTYPE') ||
          sample.contains('<html') ||
          sample.contains('Cloudflare') ||
          sample.contains('404') ||
          sample.contains('403')) {
        return false;
      }

      // Simple sanity check for ONNX files
      if (name.endsWith('.onnx')) {
        if (bytes < 1000 * 1024) {
          _log('$name: file size too small (${_mb(bytes)} MB)');
          return false;
        }
        _log('$name: ONNX file validation passed');
      }

      return bytes > 0;
    } catch (_) {
      return false;
    }
  }

  /// Downloads a file from a URL with basic retry and validation logic.
  static Future<void> _downloadWithChecks(
    String url,
    File dest,
    String name,
  ) async {
    const maxRetries = 4;

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      final tmp = File('${dest.path}.part');
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}

      _log('Downloading $name (attempt $attempt/$maxRetries)');
      final client = http.Client();

      try {
        final req = http.Request('GET', Uri.parse(url))
          ..followRedirects = true
          ..headers.addAll({'User-Agent': 'FlutterApp/1.0', 'Accept': '*/*'});

        final resp = await client
            .send(req)
            .timeout(const Duration(minutes: 20));

        if (resp.statusCode != 200) {
          await resp.stream.drain();
          throw HttpException('HTTP ${resp.statusCode}');
        }

        final sink = tmp.openWrite();
        await for (final chunk in resp.stream) {
          sink.add(chunk);
        }
        await sink.close();

        await tmp.rename(dest.path);

        if (await _isValid(name, dest)) return;
        throw const HttpException('Post-download validation failed');
      } catch (e) {
        _log('Download error for $name: $e');
        if (attempt == maxRetries) rethrow;
        await Future.delayed(Duration(milliseconds: 400 * attempt));
      } finally {
        client.close();
      }
    }
  }

  /// Converts byte count to megabytes for readable output.
  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(2);

  /// Basic logger. Replace with debugPrint if desired.
  static void _log(Object message) => print(message);
}
