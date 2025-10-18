import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

class ModelLoader {
  static const String _repo = 'onnx-community/FastVLM-0.5B-ONNX';
  static const String _base = 'https://huggingface.co';
  static const String _folder = 'models/FastVLM-0.5B-ONNX';

  // Performance constants
  static const int _chunkSize = 8 * 1024 * 1024; // 8MB chunks for optimal I/O
  static const int _maxConcurrentDownloads = 3; // Prevent overwhelming network
  static const int _validationHeaderBytes = 8192; // Check more bytes
  static const Duration _downloadTimeout = Duration(minutes: 30);
  static const int _connectionPoolSize = 10;

  /// Model file definitions with expected checksums (SHA256)
  static const Map<String, ModelFile> _models = {
    'vision_encoder.onnx': ModelFile(
      url: '$_base/$_repo/resolve/main/onnx/vision_encoder.onnx',
      minSizeMB: 220,
      sha256: null, // Add actual checksums if available
    ),
    'embed_tokens.onnx': ModelFile(
      url: '$_base/$_repo/resolve/main/onnx/embed_tokens.onnx',
      minSizeMB: 50,
      sha256: null,
    ),
    'decoder_model_merged.onnx': ModelFile(
      url:
          '$_base/$_repo/resolve/main/onnx/decoder_model_merged.onnx?download=true',
      minSizeMB: 900,
      sha256: null,
    ),
    'tokenizer.json': ModelFile(
      url: '$_base/$_repo/resolve/main/tokenizer.json',
      minSizeMB: 1,
      sha256: null,
    ),
    'preprocessor_config.json': ModelFile(
      url: '$_base/$_repo/resolve/main/preprocessor_config.json',
      minSizeMB: 0,
      sha256: null,
    ),
    'special_tokens_map.json': ModelFile(
      url: '$_base/$_repo/resolve/main/special_tokens_map.json',
      minSizeMB: 0,
      sha256: null,
    ),
    'generation_config.json': ModelFile(
      url: '$_base/$_repo/resolve/main/generation_config.json',
      minSizeMB: 0,
      sha256: null,
    ),
    'tokenizer_config.json': ModelFile(
      url: '$_base/$_repo/resolve/main/tokenizer_config.json',
      minSizeMB: 0,
      sha256: null,
    ),
  };

  // Cached directory path
  static Directory? _cachedDir;
  static http.Client? _sharedClient;

  /// Ensures all required model files with optimized concurrent downloads.
  static Future<void> ensureModelsDownloaded({
    void Function(
      String name,
      double progress,
      int bytesDownloaded,
      int totalBytes,
    )?
    onProgress,
    bool forceRedownload = false,
  }) async {
    final dir = await _targetDir();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // Initialize shared HTTP client for connection pooling
    _sharedClient ??= http.Client();

    // Quick validation pass - fail fast if any file is invalid
    if (!forceRedownload) {
      final validationFutures = _models.entries.map((e) async {
        final file = File(p.join(dir.path, e.key));
        return _QuickValidation(
          name: e.key,
          file: file,
          isValid: await _quickValidate(e.key, file, e.value),
        );
      });

      final validations = await Future.wait(validationFutures);
      final toDownload = validations.where((v) => !v.isValid).toList();

      if (toDownload.isEmpty) {
        _log('All models already cached and valid');
        return;
      }

      _log('Need to download ${toDownload.length} files');
    }

    // Download with concurrency limit
    final entries = _models.entries.toList();
    for (int i = 0; i < entries.length; i += _maxConcurrentDownloads) {
      final batch = entries.skip(i).take(_maxConcurrentDownloads);
      await Future.wait(
        batch.map(
          (e) => _ensureOne(
            e.key,
            e.value,
            onProgress: onProgress,
            forceRedownload: forceRedownload,
          ),
        ),
      );
    }

    _log('All models ready');
  }

  /// Fast path validation - checks existence and size only.
  static Future<bool> _quickValidate(
    String name,
    File file,
    ModelFile modelFile,
  ) async {
    if (!await file.exists()) return false;

    final bytes = await file.length();
    if (bytes == 0) return false;

    // Quick size check
    if (modelFile.minSizeMB > 0 && bytes < modelFile.minSizeMB * 1024 * 1024) {
      return false;
    }

    return true;
  }

  /// Deep validation with header inspection and checksum.
  static Future<bool> _deepValidate(
    String name,
    File file,
    ModelFile modelFile,
  ) async {
    try {
      if (!await file.exists()) return false;
      final bytes = await file.length();
      if (bytes == 0) return false;

      final minBytes = modelFile.minSizeMB * 1024 * 1024;
      if (modelFile.minSizeMB > 0 && bytes < minBytes) {
        _log('$name too small: ${_mb(bytes)} MB < ${modelFile.minSizeMB} MB');
        return false;
      }

      // Stream-based header check (memory efficient)
      final header = await _readHeader(file, _validationHeaderBytes);
      if (_looksLikeHTML(header)) {
        _log('$name contains HTML error page');
        return false;
      }

      // ONNX files should have specific magic bytes
      if (name.endsWith('.onnx')) {
        if (bytes < 1_000_000) {
          _log('$name: ONNX suspiciously small');
          return false;
        }
        // Check for ONNX protobuf header (optional but recommended)
        if (!_looksLikeONNX(header)) {
          _log('$name: Does not appear to be valid ONNX format');
          return false;
        }
      }

      // Checksum verification if provided
      if (modelFile.sha256 != null) {
        final hash = await _computeSHA256(file);
        if (hash != modelFile.sha256) {
          _log('$name: Checksum mismatch');
          return false;
        }
      }

      return true;
    } catch (e) {
      _log('Validation error for $name: $e');
      return false;
    }
  }

  /// Reads file header efficiently.
  static Future<Uint8List> _readHeader(File file, int maxBytes) async {
    final raf = await file.open(mode: FileMode.read);
    try {
      final length = await raf.length();
      final toRead = length < maxBytes ? length : maxBytes;
      final buffer = Uint8List(toRead);
      await raf.readInto(buffer);
      return buffer;
    } finally {
      await raf.close();
    }
  }

  /// Checks if bytes look like HTML error page.
  static bool _looksLikeHTML(Uint8List bytes) {
    // Check first 512 bytes only for performance
    final checkLen = bytes.length < 512 ? bytes.length : 512;
    final sample = String.fromCharCodes(
      bytes.sublist(0, checkLen),
    ).toLowerCase();

    return sample.contains('<html') ||
        sample.contains('<!doctype') ||
        sample.contains('error 403') ||
        sample.contains('error 404') ||
        sample.contains('access denied');
  }

  /// Checks if bytes look like ONNX protobuf format.
  static bool _looksLikeONNX(Uint8List bytes) {
    if (bytes.length < 4) return false;

    // ONNX files are protobuf format - check for protobuf markers
    // Protobuf typically starts with field numbers and wire types
    // This is a basic heuristic - ONNX files often have "ir_version" early
    final sample = String.fromCharCodes(bytes.take(200));
    return sample.contains('ir_version') ||
        sample.contains('producer_name') ||
        (bytes[0] >= 0x08 && bytes[0] <= 0x12); // Common protobuf field tags
  }

  /// Computes SHA256 hash efficiently with streaming.
  static Future<String> _computeSHA256(File file) async {
    final stream = file.openRead();
    final hash = await sha256.bind(stream).first;
    return hash.toString();
  }

  /// Ensures single model file with optimized download.
  static Future<void> _ensureOne(
    String name,
    ModelFile modelFile, {
    void Function(
      String name,
      double progress,
      int bytesDownloaded,
      int totalBytes,
    )?
    onProgress,
    bool forceRedownload = false,
  }) async {
    final dir = await _targetDir();
    final file = File(p.join(dir.path, name));

    // Skip if valid and not forcing redownload
    if (!forceRedownload && await _deepValidate(name, file, modelFile)) {
      _log('✓ Cached $name (${_mb(await file.length())} MB)');
      return;
    }

    await file.parent.create(recursive: true);
    await _downloadOptimized(modelFile.url, file, name, onProgress: onProgress);

    if (!await _deepValidate(name, file, modelFile)) {
      await file.delete().catchError((e) {
        _log('Warning: Failed to delete invalid file: $e');
      });
      throw HttpException('Downloaded $name but validation failed');
    }

    _log('✓ Downloaded $name (${_mb(await file.length())} MB)');
  }

  /// Optimized download with chunked streaming and progress.
  static Future<void> _downloadOptimized(
    String url,
    File dest,
    String name, {
    void Function(
      String name,
      double progress,
      int bytesDownloaded,
      int totalBytes,
    )?
    onProgress,
  }) async {
    const maxRetries = 3;

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      final tmp = File('${dest.path}.tmp${Platform.isWindows ? '.tmp' : ''}');
      if (await tmp.exists()) await tmp.delete();

      if (attempt > 1) {
        _log('Retry $attempt/$maxRetries for $name');
      }

      try {
        final client = _sharedClient ?? http.Client();
        final request = http.Request('GET', Uri.parse(url))
          ..followRedirects = true
          ..headers.addAll({
            'User-Agent': 'FastVLM/2.0',
            'Accept': '*/*',
            'Connection': 'keep-alive',
          });

        final response = await client.send(request).timeout(_downloadTimeout);

        if (response.statusCode != 200) {
          await response.stream.drain();
          throw HttpException('HTTP ${response.statusCode} for $name');
        }

        final totalBytes = response.contentLength ?? 0;
        int downloadedBytes = 0;

        // Stream to file with progress tracking
        final sink = tmp.openWrite();

        try {
          await for (final chunk in response.stream) {
            sink.add(chunk);
            downloadedBytes += chunk.length;

            if (onProgress != null && totalBytes > 0) {
              final progress = downloadedBytes / totalBytes;
              onProgress(name, progress, downloadedBytes, totalBytes);
            }
          }

          await sink.flush();
          await sink.close();
        } catch (e) {
          await sink.close();
          rethrow;
        }

        // Atomic rename
        await tmp.rename(dest.path);

        _log('Downloaded $name: ${_mb(downloadedBytes)} MB');
        return;
      } catch (e) {
        _log('Download error for $name (attempt $attempt): $e');

        if (await tmp.exists()) {
          await tmp.delete().catchError((_) {});
        }

        if (attempt == maxRetries) rethrow;

        // Exponential backoff
        await Future.delayed(Duration(seconds: 1 << (attempt - 1)));
      }
    }
  }

  /// Returns cached model paths with minimal I/O.
  static Future<Map<String, String>> getAllModelPaths() async {
    final dir = await _targetDir();
    final result = <String, String>{};

    // Quick existence check without deep validation
    for (final entry in _models.entries) {
      final file = File(p.join(dir.path, entry.key));
      if (!await file.exists()) {
        throw FileSystemException('Model file missing', file.path);
      }
      result[entry.key] = file.path;
    }

    return result;
  }

  /// Fast inventory with cached results.
  static Future<void> printInventory() async {
    final dir = await _targetDir();
    if (!await dir.exists()) {
      _log('Model directory not found');
      return;
    }

    _log('Model directory: ${dir.path}');

    // Stream directory listing for performance
    await for (final entity in dir.list()) {
      if (entity is File) {
        final len = await entity.length();
        _log(' - ${p.basename(entity.path)} (${_mb(len)} MB)');
      }
    }
  }

  /// Cached directory path.
  static Future<Directory> _targetDir() async {
    if (_cachedDir != null) return _cachedDir!;

    final base = await getApplicationDocumentsDirectory();
    _cachedDir = Directory(p.join(base.path, _folder));
    return _cachedDir!;
  }

  /// Cleanup resources.
  static void dispose() {
    _sharedClient?.close();
    _sharedClient = null;
    _cachedDir = null;
  }

  /// Byte to MB conversion.
  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(2);

  /// Logger.
  static void _log(Object message) => print('[ModelLoader] $message');
}

/// Model file metadata.
class ModelFile {
  final String url;
  final int minSizeMB;
  final String? sha256;

  const ModelFile({required this.url, required this.minSizeMB, this.sha256});
}

/// Quick validation result.
class _QuickValidation {
  final String name;
  final File file;
  final bool isValid;

  const _QuickValidation({
    required this.name,
    required this.file,
    required this.isValid,
  });
}
