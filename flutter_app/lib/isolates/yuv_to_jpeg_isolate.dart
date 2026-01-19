// lib/isolates/yuv_to_jpeg_isolate.dart
//
// Convert YUV420 planes (bytes snapshot) -> JPEG bytes in an isolate.
// Safe for compute(): only passes primitives + Uint8List.

import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Top-level function required by `compute`.
Uint8List yuvToJpegIsolate(Map<String, dynamic> args) {
  final int width = args['width'] as int;
  final int height = args['height'] as int;

  final Uint8List yBytes = args['y'] as Uint8List;
  final Uint8List uBytes = args['u'] as Uint8List;
  final Uint8List vBytes = args['v'] as Uint8List;

  final int yRowStride = args['yRowStride'] as int;
  final int uvRowStride = args['uvRowStride'] as int;
  final int uvPixelStride = (args['uvPixelStride'] as int?) ?? 1;

  final int maxSide = (args['maxSide'] as int?) ?? 512;
  final int jpegQuality = (args['jpegQuality'] as int?) ?? 70;
  final int rotation = (args['rotation'] as int?) ?? 0; // 0/90/180/270

  final rgb = _yuv420ToRgbImage(
    width: width,
    height: height,
    yBytes: yBytes,
    uBytes: uBytes,
    vBytes: vBytes,
    yRowStride: yRowStride,
    uvRowStride: uvRowStride,
    uvPixelStride: uvPixelStride,
  );

  final resized = _resizeMaxSide(rgb, maxSide);
  final rotated = _applyRotation(resized, rotation);

  final jpg = img.encodeJpg(rotated, quality: jpegQuality);
  return Uint8List.fromList(jpg);
}

img.Image _yuv420ToRgbImage({
  required int width,
  required int height,
  required Uint8List yBytes,
  required Uint8List uBytes,
  required Uint8List vBytes,
  required int yRowStride,
  required int uvRowStride,
  required int uvPixelStride,
}) {
  final out = img.Image(width: width, height: height);

  for (int y = 0; y < height; y++) {
    final int yRow = y * yRowStride;
    final int uvRow = (y >> 1) * uvRowStride;

    for (int x = 0; x < width; x++) {
      final int yIndex = yRow + x;
      final int uvIndex = uvRow + (x >> 1) * uvPixelStride;

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

  return out;
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

img.Image _applyRotation(img.Image input, int rotationDegrees) {
  final r = ((rotationDegrees % 360) + 360) % 360;
  switch (r) {
    case 90:
      return img.copyRotate(input, angle: 90);
    case 180:
      return img.copyRotate(input, angle: 180);
    case 270:
      return img.copyRotate(input, angle: 270);
    default:
      return input;
  }
}
