import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

/// Handles YUV → RGB conversion and normalization for ONNX models.
class ImageUtils {
  static const int _uvCenter = 128;
  static const int _yuvRCoeffV = 91;
  static const int _yuvGCoeffU = 22;
  static const int _yuvGCoeffV = 46;
  static const int _yuvBCoeffU = 113;
  static const int _yuvShift = 6;

  static const List<double> mean = [0.48145466, 0.4578275, 0.40821073];
  static const List<double> std = [0.26862954, 0.26130258, 0.27577711];

  /// Converts a YUV camera frame to a normalized Float32 tensor [1, 3, sz, sz].
  static Float32List preprocess(CameraImage im, int sz) {
    final invStd = [1 / std[0], 1 / std[1], 1 / std[2]];
    final rgbBytes = _yuvToRgb(im);
    final imgRGB = img.Image.fromBytes(
      width: im.width,
      height: im.height,
      bytes: rgbBytes.buffer,
      numChannels: 3,
    );
    final resized = img.copyResize(
      imgRGB,
      width: sz,
      height: sz,
      interpolation: img.Interpolation.linear,
    );
    return _normalize(resized, mean, invStd);
  }

  static Uint8List _yuvToRgb(CameraImage im) {
    final w = im.width, h = im.height;
    final rgbBytes = Uint8List(w * h * 3);
    int idx = 0;

    final y = im.planes[0].bytes;
    final u = im.planes[1].bytes;
    final v = im.planes[2].bytes;
    final yrs = im.planes[0].bytesPerRow;
    final urs = im.planes[1].bytesPerRow;
    final ups = im.planes[1].bytesPerPixel!;

    for (int r = 0; r < h; r++) {
      final yOff = r * yrs;
      final uvRow = (r >> 1) * urs;
      for (int c = 0; c < w; c++) {
        final uvCol = (c >> 1) * ups;
        final Y = y[yOff + c];
        final U = u[uvRow + uvCol] - _uvCenter;
        final V = v[uvRow + uvCol] - _uvCenter;

        rgbBytes[idx++] = _clamp(Y + ((V * _yuvRCoeffV) >> _yuvShift));
        rgbBytes[idx++] = _clamp(
          Y - ((U * _yuvGCoeffU + V * _yuvGCoeffV) >> _yuvShift),
        );
        rgbBytes[idx++] = _clamp(Y + ((U * _yuvBCoeffU) >> _yuvShift));
      }
    }
    return rgbBytes;
  }

  static Float32List _normalize(
    img.Image input,
    List<double> mean,
    List<double> invStd,
  ) {
    final t = input.width;
    final plane = t * t;
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

  static int _clamp(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);
}
