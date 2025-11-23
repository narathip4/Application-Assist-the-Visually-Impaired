import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

class ImageUtils {
  // --- YUV → RGB coefficients (integer math optimized) ---
  static const int _uvCenter = 128;
  static const int _yuvRCoeffV = 91;
  static const int _yuvGCoeffU = 22;
  static const int _yuvGCoeffV = 46;
  static const int _yuvBCoeffU = 113;
  static const int _yuvShift = 6; // Right-shift for fixed-point scaling

  // --- CLIP normalization constants ---
  static const List<double> mean = [0.48145466, 0.4578275, 0.40821073];
  static const List<double> std = [0.26862954, 0.26130258, 0.27577711];

  /// Converts a `CameraImage` (YUV420) to a normalized Float32 tensor.

  /// Output tensor layout: `[3 * sz * sz]`, channel-first.
  static Float32List preprocess(CameraImage im, int sz) {
    final invStd = [1 / std[0], 1 / std[1], 1 / std[2]];

    // Convert to RGB byte array
    final rgbBytes = _yuvToRgb(im);

    // Decode to image buffer
    final imgRGB = img.Image.fromBytes(
      width: im.width,
      height: im.height,
      bytes: rgbBytes.buffer,
      numChannels: 3,
    );

    // Resize using bilinear interpolation
    final resized = img.copyResize(
      imgRGB,
      width: sz,
      height: sz,
      interpolation: img.Interpolation.linear,
    );

    // Normalize into Float32 tensor
    return _normalize(resized, mean, invStd);
  }

  /// Converts YUV420 camera buffer to planar RGB byte array.
  ///
  /// Performs integer arithmetic for performance.
  /// Suitable for real-time mobile inference.
  static Uint8List _yuvToRgb(CameraImage im) {
    final w = im.width, h = im.height;
    final rgbBytes = Uint8List(w * h * 3);
    int idx = 0;

    // Access Y, U, V planes
    final y = im.planes[0].bytes;
    final u = im.planes[1].bytes;
    final v = im.planes[2].bytes;

    final yRowStride = im.planes[0].bytesPerRow;
    final uRowStride = im.planes[1].bytesPerRow;
    final uPixelStride = im.planes[1].bytesPerPixel!;

    for (int r = 0; r < h; r++) {
      final yOff = r * yRowStride;
      final uvRow = (r >> 1) * uRowStride;
      for (int c = 0; c < w; c++) {
        final uvCol = (c >> 1) * uPixelStride;
        final Y = y[yOff + c];
        final U = u[uvRow + uvCol] - _uvCenter;
        final V = v[uvRow + uvCol] - _uvCenter;

        // Integer math for RGB channels
        rgbBytes[idx++] = _clamp(Y + ((V * _yuvRCoeffV) >> _yuvShift));
        rgbBytes[idx++] = _clamp(
          Y - ((U * _yuvGCoeffU + V * _yuvGCoeffV) >> _yuvShift),
        );
        rgbBytes[idx++] = _clamp(Y + ((U * _yuvBCoeffU) >> _yuvShift));
      }
    }
    return rgbBytes;
  }

  /// Normalizes RGB image channels to zero-mean, unit-variance Float32.
  ///
  /// Channel order: R, G, B (each contiguous).
  static Float32List _normalize(
    img.Image input,
    List<double> mean,
    List<double> invStd,
  ) {
    final side = input.width;
    final plane = side * side;
    final out = Float32List(3 * plane);
    int pi = 0;

    for (final px in input) {
      out[pi] = (px.rNormalized - mean[0]) * invStd[0];
      out[pi + plane] = (px.gNormalized - mean[1]) * invStd[1];
      out[pi + 2 * plane] = (px.bNormalized - mean[2]) * invStd[2];
      pi++;
    }
    return out;
  }

  /// Clamps RGB component values into [0, 255] range.
  static int _clamp(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);
}
