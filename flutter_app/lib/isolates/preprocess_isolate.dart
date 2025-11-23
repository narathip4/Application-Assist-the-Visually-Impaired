import 'dart:typed_data';
import 'package:camera/camera.dart';
import '../utils/image_utils.dart';

/// Wrapper function for use with `compute()`
/// Converts CameraImage → Float32List tensor in a background isolate.
Float32List preprocessInIsolate(Map<String, dynamic> data) {
  final CameraImage image = data['image'];
  final int size = data['size'];
  return ImageUtils.preprocess(image, size);
}
