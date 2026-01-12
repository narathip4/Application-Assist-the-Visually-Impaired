import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

class ImageUtils {
  static Uint8List cameraImageToJpeg(
    CameraImage cameraImage, {
    required int maxSide,
    required int jpegQuality,
  }) {
    // Convert YUV420 -> RGB (slow but reliable)
    final width = cameraImage.width;
    final height = cameraImage.height;

    final uvRowStride = cameraImage.planes[1].bytesPerRow;
    final uvPixelStride = cameraImage.planes[1].bytesPerPixel ?? 1;

    final out = img.Image(width: width, height: height);

    final yPlane = cameraImage.planes[0].bytes;
    final uPlane = cameraImage.planes[1].bytes;
    final vPlane = cameraImage.planes[2].bytes;

    for (int y = 0; y < height; y++) {
      final yRow = y * cameraImage.planes[0].bytesPerRow;
      final uvRow = (y >> 1) * uvRowStride;

      for (int x = 0; x < width; x++) {
        final yIndex = yRow + x;

        final uvIndex = uvRow + (x >> 1) * uvPixelStride;
        final yp = yPlane[yIndex];

        final up = uPlane[uvIndex];
        final vp = vPlane[uvIndex];

        // YUV -> RGB
        int r = (yp + (1.370705 * (vp - 128))).round();
        int g = (yp - (0.337633 * (up - 128)) - (0.698001 * (vp - 128))).round();
        int b = (yp + (1.732446 * (up - 128))).round();

        r = r.clamp(0, 255);
        g = g.clamp(0, 255);
        b = b.clamp(0, 255);

        out.setPixelRgb(x, y, r, g, b);
      }
    }

    // Resize to maxSide (keeps aspect ratio)
    final resized = _resizeMaxSide(out, maxSide);

    // Encode to JPEG
    final jpg = img.encodeJpg(resized, quality: jpegQuality);
    return Uint8List.fromList(jpg);
  }

  static img.Image _resizeMaxSide(img.Image input, int maxSide) {
    final w = input.width;
    final h = input.height;
    final maxWH = w > h ? w : h;
    if (maxWH <= maxSide) return input;

    final scale = maxSide / maxWH;
    final nw = (w * scale).round();
    final nh = (h * scale).round();
    return img.copyResize(input, width: nw, height: nh);
  }
}
