// lib/isolates/yuv_to_jpeg_isolate.dart
//
// Purpose: Convert CameraImage (YUV420) -> JPEG bytes in an isolate.
// Use with `compute(yuvToJpegIsolate, {...})`.
//
// Requires: pubspec.yaml -> dependencies: image: ^4.x
//
// Note: This is CPU-heavy; always run in an isolate, not on the UI thread.

import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

class YuvToJpegArgs {
  final CameraImage image;
  final int maxSide; // e.g. 512
  final int jpegQuality; // e.g. 70

  const YuvToJpegArgs({
    required this.image,
    required this.maxSide,
    required this.jpegQuality,
  });

  // compute() only accepts simple types; we pass Map in practice.
  static Map<String, dynamic> toMap(YuvToJpegArgs a) => {
        'image': a.image,
        'maxSide': a.maxSide,
        'jpegQuality': a.jpegQuality,
      };
}

/// Top-level function required by `compute`.
Uint8List yuvToJpegIsolate(Map<String, dynamic> args) {
  final CameraImage cameraImage = args['image'] as CameraImage;
  final int maxSide = (args['maxSide'] as int?) ?? 512;
  final int jpegQuality = (args['jpegQuality'] as int?) ?? 70;

  return _cameraImageToJpeg(cameraImage, maxSide: maxSide, jpegQuality: jpegQuality);
}

Uint8List _cameraImageToJpeg(
  CameraImage cameraImage, {
  required int maxSide,
  required int jpegQuality,
}) {
  if (cameraImage.format.group != ImageFormatGroup.yuv420) {
    throw StateError('Unsupported image format: ${cameraImage.format.group}');
  }

  final width = cameraImage.width;
  final height = cameraImage.height;

  final yPlane = cameraImage.planes[0];
  final uPlane = cameraImage.planes[1];
  final vPlane = cameraImage.planes[2];

  final yBytes = yPlane.bytes;
  final uBytes = uPlane.bytes;
  final vBytes = vPlane.bytes;

  final yRowStride = yPlane.bytesPerRow;
  final uvRowStride = uPlane.bytesPerRow;
  final uvPixelStride = uPlane.bytesPerPixel ?? 1;

  // Build RGB image
  final out = img.Image(width: width, height: height);

  for (int y = 0; y < height; y++) {
    final yRow = y * yRowStride;
    final uvRow = (y >> 1) * uvRowStride;

    for (int x = 0; x < width; x++) {
      final yIndex = yRow + x;

      final uvIndex = uvRow + (x >> 1) * uvPixelStride;

      final int yp = yBytes[yIndex];
      final int up = uBytes[uvIndex];
      final int vp = vBytes[uvIndex];

      // YUV -> RGB (BT.601)
      int r = (yp + (1.370705 * (vp - 128))).round();
      int g = (yp - (0.337633 * (up - 128)) - (0.698001 * (vp - 128))).round();
      int b = (yp + (1.732446 * (up - 128))).round();

      if (r < 0) r = 0;
      if (r > 255) r = 255;
      if (g < 0) g = 0;
      if (g > 255) g = 255;
      if (b < 0) b = 0;
      if (b > 255) b = 255;

      out.setPixelRgb(x, y, r, g, b);
    }
  }

  // Resize to maxSide (keep aspect ratio)
  final resized = _resizeMaxSide(out, maxSide);

  // Encode JPEG
  final jpg = img.encodeJpg(resized, quality: jpegQuality);
  return Uint8List.fromList(jpg);
}

img.Image _resizeMaxSide(img.Image input, int maxSide) {
  final w = input.width;
  final h = input.height;
  final int longest = w > h ? w : h;

  if (longest <= maxSide) return input;

  final scale = maxSide / longest;
  final nw = (w * scale).round();
  final nh = (h * scale).round();

  return img.copyResize(input, width: nw, height: nh);
}
