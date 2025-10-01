import 'dart:io';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';

// Callback used to report progress while downloading
typedef ProgressCallback =
    void Function(
      String fileName,
      int downloadedBytes,
      int totalBytes,
      double percentage,
    );

// Loader for downloading & caching ONNX models
class ModelLoader {
  // Hugging Face repo where ONNX models are stored
  static const String _repoBaseUrl =
      "https://huggingface.co/onnx-community/FastVLM-0.5B-ONNX/resolve/main/onnx";

  // List of model files required
  static const List<String> _requiredFiles = [
    "decoder_model_merged_int8.onnx",
    "embed_tokens_int8.onnx",
    "vision_encoder_int8.onnx",
  ];

  // (Optional) File checksums to verify integrity
  static const Map<String, String>? _checksums = null;

  // Retry & timeout settings
  static const int _maxRetries = 3;
  static const Duration _timeout = Duration(minutes: 30);
  static const Duration _retryDelay = Duration(seconds: 3);
  static const int _chunkSize = 8192; // 8 KB

  static http.Client? _client;

  // Return app's local folder where models will be stored
  static Future<String> _getModelDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory("${base.path}/models/FastVLM-0.5B-ONNX");
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  // Format size to human-readable string
  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  // Download a single model file with retries
  static Future<void> _downloadFile(
    String url,
    String filePath, {
    ProgressCallback? onProgress,
    int retryCount = 0,
  }) async {
    final fileName = url.split('/').last;
    _client ??= http.Client();

    try {
      final response = await _client!
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(_timeout);

      if (response.statusCode != 200) {
        throw HttpException("HTTP ${response.statusCode}", uri: Uri.parse(url));
      }

      final total = response.contentLength ?? 0;
      int downloaded = 0;

      final file = File(filePath);
      final sink = file.openWrite();

      try {
        await for (final chunk in response.stream) {
          // Write in chunks
          for (int i = 0; i < chunk.length; i += _chunkSize) {
            final end = (i + _chunkSize < chunk.length)
                ? i + _chunkSize
                : chunk.length;
            sink.add(chunk.sublist(i, end));
            downloaded += (end - i);

            // Report progress
            onProgress?.call(
              fileName,
              downloaded,
              total,
              total > 0 ? (downloaded / total * 100) : 0,
            );
          }
        }

        await sink.flush();
        await sink.close();

        // Verify file size
        if (total > 0 && (await file.length()) != total) {
          throw Exception("File size mismatch for $fileName");
        }

        // Verify checksum if provided
        if (_checksums != null && _checksums!.containsKey(fileName)) {
          final ok = await _verifyChecksum(filePath, _checksums![fileName]!);
          if (!ok) {
            await file.delete();
            throw Exception("Checksum failed for $fileName");
          }
        }

        print("✓ Downloaded $fileName (${_formatBytes(downloaded)})");
      } catch (e) {
        await sink.close();
        if (await file.exists()) await file.delete();
        rethrow;
      }
    } catch (e) {
      // Retry if failed
      if (retryCount < _maxRetries) {
        print("⚠ Retry ${retryCount + 1}/$_maxRetries for $fileName: $e");
        await Future.delayed(_retryDelay * (retryCount + 1));
        return _downloadFile(
          url,
          filePath,
          onProgress: onProgress,
          retryCount: retryCount + 1,
        );
      }
      rethrow;
    }
  }

  /// Verify checksum of a file
  static Future<bool> _verifyChecksum(String filePath, String expected) async {
    final file = File(filePath);
    final digest = sha256.convert(await file.readAsBytes()).toString();
    return digest == expected;
  }

  /// Ensure all model files are downloaded (skip if already cached)
  static Future<void> ensureModelsDownloaded({
    ProgressCallback? onProgress,
  }) async {
    final dir = await _getModelDir();

    for (final fileName in _requiredFiles) {
      final filePath = "$dir/$fileName";
      final file = File(filePath);

      if (await file.exists() && (await file.length()) > 0) {
        print("✓ Cached $fileName (${_formatBytes(await file.length())})");
        continue;
      }

      final url = "$_repoBaseUrl/$fileName";
      print("⬇ Downloading $fileName ...");
      await _downloadFile(url, filePath, onProgress: onProgress);
    }

    print("✓ All models ready!");
  }

  /// Check if all required models exist locally
  static Future<bool> isReady() async {
    final dir = await _getModelDir();
    for (final f in _requiredFiles) {
      final file = File("$dir/$f");
      if (!await file.exists() || (await file.length()) == 0) {
        return false;
      }
    }
    return true;
  }

  /// Get local path of a model file
  static Future<String> getModelPath(String fileName) async {
    final dir = await _getModelDir();
    final path = "$dir/$fileName";
    if (!await File(path).exists()) {
      throw FileSystemException("Model not found", path);
    }
    return path;
  }

  /// Clear all cached models (force re-download next time)
  static Future<void> clearCache() async {
    final dir = await _getModelDir();
    for (final f in _requiredFiles) {
      final file = File("$dir/$f");
      if (await file.exists()) {
        await file.delete();
        print("✗ Deleted $f");
      }
    }
  }

  /// Dispose HTTP client
  static Future<void> dispose() async {
    _client?.close();
    _client = null;
  }
}
