import 'dart:typed_data';

import 'package:image/image.dart' as img;

class SequenceImageUtils {
  /// Combines consecutive JPEG frames into a single horizontal strip.
  /// The VLM can then reason over short-term temporal change in one request.
  static Uint8List composeHorizontalStrip(List<Uint8List> jpegFrames) {
    if (jpegFrames.isEmpty) return Uint8List(0);
    if (jpegFrames.length == 1) return jpegFrames.first;

    final decoded = <img.Image>[];
    for (final bytes in jpegFrames) {
      final frame = img.decodeJpg(bytes);
      if (frame != null) decoded.add(frame);
    }

    if (decoded.isEmpty) return Uint8List(0);
    if (decoded.length == 1) return Uint8List.fromList(img.encodeJpg(decoded[0]));

    final targetHeight = decoded.first.height;
    final normalized = decoded
        .map((frame) {
          if (frame.height == targetHeight) return frame;
          final newWidth = (frame.width * targetHeight / frame.height).round();
          return img.copyResize(frame, width: newWidth, height: targetHeight);
        })
        .toList();

    final totalWidth = normalized.fold<int>(0, (sum, f) => sum + f.width);
    final strip = img.Image(width: totalWidth, height: targetHeight);

    var xOffset = 0;
    for (final frame in normalized) {
      img.compositeImage(strip, frame, dstX: xOffset, dstY: 0);
      xOffset += frame.width;
    }

    return Uint8List.fromList(img.encodeJpg(strip, quality: 60));
  }
}
