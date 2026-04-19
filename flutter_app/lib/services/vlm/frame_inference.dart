import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import '../../app/config.dart';
import '../../isolates/yuv_to_jpeg_isolate.dart';
import 'fast_vlm_service.dart';

class YuvFrameSnapshot {
  final int width;
  final int height;
  final Uint8List yBytes;
  final Uint8List uBytes;
  final Uint8List vBytes;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;

  const YuvFrameSnapshot({
    required this.width,
    required this.height,
    required this.yBytes,
    required this.uBytes,
    required this.vBytes,
    required this.yRowStride,
    required this.uvRowStride,
    required this.uvPixelStride,
  });

  factory YuvFrameSnapshot.fromCameraImage(CameraImage img) {
    final yPlane = img.planes[0];
    final uPlane = img.planes[1];
    final vPlane = img.planes[2];

    return YuvFrameSnapshot(
      width: img.width,
      height: img.height,
      yBytes: Uint8List.fromList(yPlane.bytes),
      uBytes: Uint8List.fromList(uPlane.bytes),
      vBytes: Uint8List.fromList(vPlane.bytes),
      yRowStride: yPlane.bytesPerRow,
      uvRowStride: uPlane.bytesPerRow,
      uvPixelStride: uPlane.bytesPerPixel ?? 1,
    );
  }
}

class FrameInference {
  final FastVlmService vlmService;

  FrameInference({required this.vlmService});

  Future<Uint8List> yuvToJpeg(YuvFrameSnapshot frame, int rotation) async {
    return compute(yuvToJpegIsolate, <String, dynamic>{
      'width': frame.width,
      'height': frame.height,
      'y': frame.yBytes,
      'u': frame.uBytes,
      'v': frame.vBytes,
      'yRowStride': frame.yRowStride,
      'uvRowStride': frame.uvRowStride,
      'uvPixelStride': frame.uvPixelStride,
      'maxSide': AppConfig.jpegMaxSide,
      'jpegQuality': AppConfig.jpegQuality,
      'rotation': rotation,
    });
  }

  Future<String> describeJpegBytesWithPrompt(
    Uint8List jpegBytes, {
    required String prompt,
    int? maxNewTokens,
  }) async {
    final totalTimeout = Duration(
      milliseconds: (vlmService.timeout.inMilliseconds * 3) + 5000,
    );
    final resp = await vlmService
        .describeJpegBytes(
          jpegBytes,
          prompt: prompt,
          maxNewTokens: maxNewTokens ?? AppConfig.maxNewTokens,
        )
        .timeout(
          totalTimeout,
          onTimeout: () => throw TimeoutException('VLM request timed out'),
        );
    return resp.say;
  }
}
