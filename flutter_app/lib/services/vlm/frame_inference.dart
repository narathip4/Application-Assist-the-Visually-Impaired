import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import '../../app/config.dart';
import '../../isolates/yuv_to_jpeg_isolate.dart';
import 'fast_vlm_service.dart';

class FrameInference {
  final FastVlmService vlmService;

  FrameInference({required this.vlmService});

  Future<Uint8List> yuvToJpeg(CameraImage img, int rotation) async {
    final yPlane = img.planes[0];
    final uPlane = img.planes[1];
    final vPlane = img.planes[2];

    return compute(yuvToJpegIsolate, <String, dynamic>{
      'width': img.width,
      'height': img.height,
      'y': Uint8List.fromList(yPlane.bytes),
      'u': Uint8List.fromList(uPlane.bytes),
      'v': Uint8List.fromList(vPlane.bytes),
      'yRowStride': yPlane.bytesPerRow,
      'uvRowStride': uPlane.bytesPerRow,
      'uvPixelStride': uPlane.bytesPerPixel ?? 1,
      'maxSide': AppConfig.jpegMaxSide,
      'jpegQuality': AppConfig.jpegQuality,
      'rotation': rotation,
    });
  }

  Future<String> describe(CameraImage img, {required int rotation}) async {
    final jpegBytes = await yuvToJpeg(img, rotation);
    return describeJpegBytes(jpegBytes);
  }

  Future<String> describeJpegBytes(Uint8List jpegBytes) async {
    return describeJpegBytesWithPrompt(jpegBytes, prompt: AppConfig.prompt);
  }

  Future<String> describeJpegBytesWithPrompt(
    Uint8List jpegBytes, {
    required String prompt,
  }) async {
    final resp = await vlmService
        .describeJpegBytes(
          jpegBytes,
          prompt: prompt,
          maxNewTokens: AppConfig.maxNewTokens,
        )
        .timeout(
          const Duration(seconds: 60),
          onTimeout: () => throw TimeoutException('VLM request timed out'),
        );
    return resp.say;
  }
}
