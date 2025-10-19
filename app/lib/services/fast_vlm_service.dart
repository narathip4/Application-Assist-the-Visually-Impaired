import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'onnx_model_loader.dart';

/// Lightweight tokenizer interface expected from tokenizer_service.dart
abstract class Vocab {
  int get bosId;
  int get eosId;
  List<int> encode(String text);
  String decode(List<int> ids);
}

class FastVlmService {
  FastVlmService({required Vocab tokenizer}) : _tok = tokenizer;

  final Vocab _tok;

  // ONNX sessions
  OrtSession? _vision;
  OrtSession? _embed;
  OrtSession? _dec;

  // One-time init guard
  Completer<void>? _initOnce;

  // Image preprocessing constants
  static const int _sz = 256;
  static const List<double> _mean = [0.48145466, 0.4578275, 0.40821073];
  static const List<double> _std = [0.26862954, 0.26130258, 0.27577711];
  static final List<double> _invStd = [1 / _std[0], 1 / _std[1], 1 / _std[2]];

  // YUV conversion constants
  static const int _uvCenter = 128;
  static const int _yuvRCoeffV = 91;
  static const int _yuvGCoeffU = 22;
  static const int _yuvGCoeffV = 46;
  static const int _yuvBCoeffU = 113;
  static const int _yuvShift = 6;

  // Decoder IO metadata cache
  late final bool _hasInputIds;
  late final bool _hasAttentionMask;
  late final bool _hasPositionIds;
  late final Set<String> _stateKeys;
  late final Set<String> _pastKeyNames;
  late final String _logitsKey;

  bool get isReady => _vision != null && _embed != null && _dec != null;

  /// Ensure all three ONNX sessions are created and IO metadata cached.
  Future<void> ensureInitialized() async {
    if (isReady) return;
    if (_initOnce != null) return _initOnce!.future;

    final c = _initOnce = Completer<void>();
    final initStart = DateTime.now();
    debugPrint('[FastVlmService] Initialization started');

    try {
      await ModelLoader.ensureModelsDownloaded();
      final paths = await ModelLoader.getAllModelPaths();

      final ort = OnnxRuntime();
      final opts = OrtSessionOptions(
        intraOpNumThreads: 2,
        interOpNumThreads: 1,
      );

      // Load sessions in parallel
      await Future.wait([
        () async {
          _vision = await ort.createSession(
            paths['vision_encoder.onnx']!,
            options: opts,
          );
        }(),
        () async {
          _embed = await ort.createSession(
            paths['embed_tokens.onnx']!,
            options: opts,
          );
        }(),
        () async {
          _dec = await ort.createSession(
            paths['decoder_model_merged.onnx']!,
            options: opts,
          );
        }(),
      ]);

      // Cache decoder IO names
      final decInputs = _dec!.inputNames.toSet();
      final decOutputs = _dec!.outputNames.toSet();

      _hasInputIds = decInputs.contains('input_ids');
      _hasAttentionMask = decInputs.contains('attention_mask');
      _hasPositionIds = decInputs.contains('position_ids');

      // Past KV input names. Some models expose them as past_key_values.X.{key,value}
      _pastKeyNames = decInputs
          .where(
            (k) =>
                k.startsWith('past_key_values') ||
                k.contains('.key') ||
                k.contains('.value'),
          )
          .toSet();

      // Decoder state outputs that must be fed back next step
      _stateKeys = decOutputs
          .where(
            (k) => k.startsWith('present') || k.startsWith('past_key_values'),
          )
          .toSet();

      _logitsKey = _findLogitsKey(decOutputs);

      final dt = DateTime.now().difference(initStart).inMilliseconds;
      debugPrint('[FastVlmService] Initialization completed in ${dt}ms');
      debugPrint(
        '[FastVlmService] Sessions ready: vision=${_vision != null}, embed=${_embed != null}, dec=${_dec != null}',
      );
      debugPrint('[FastVlmService] Decoder inputs: ${decInputs.join(", ")}');
      debugPrint('[FastVlmService] Decoder outputs: ${decOutputs.join(", ")}');
      debugPrint('[FastVlmService] Logits key: $_logitsKey');
      debugPrint(
        '[FastVlmService] Uses attention_mask=${_hasAttentionMask}, position_ids=${_hasPositionIds}, input_ids=${_hasInputIds}',
      );

      c.complete();
    } catch (e, st) {
      debugPrint('[FastVlmService] Initialization failed: $e');
      c.completeError(e, st);
      rethrow;
    } finally {
      _initOnce = null;
    }
  }

  String _findLogitsKey(Set<String> outputs) {
    if (outputs.contains('logits')) return 'logits';
    if (outputs.contains('lm_logits')) return 'lm_logits';
    // Fallback: pick the first non-state tensor
    for (final name in outputs) {
      if (!name.startsWith('present') && !name.startsWith('past_key_values')) {
        return name;
      }
    }
    return 'logits';
  }

  /// Main API. Takes a CameraImage frame, runs end-to-end inference, and returns decoded text.
  Future<String> describeCameraImage(
    CameraImage frame, {
    String prompt = 'Describe this image for a visually impaired person.',
    int maxNewTokens = 24,
  }) async {
    final t0 = DateTime.now();
    debugPrint(
      '[FastVlmService] describeCameraImage start. Prompt="${prompt}", maxNewTokens=$maxNewTokens',
    );

    await ensureInitialized();
    if (!isReady) {
      throw StateError('FastVLM not initialized');
    }

    // Preprocess image in an isolate to keep UI responsive.
    debugPrint('[FastVlmService] Preprocess start');
    final prep = await compute<_Pack, _PrepOut>(
      _preprocess,
      _Pack.fromCamera(frame, _sz, _mean, _invStd),
    );
    debugPrint('[FastVlmService] Preprocess done');

    final cleanup = <OrtValue>[];

    try {
      // 1) Vision encoder
      debugPrint('[FastVlmService] Vision encode start');
      final px = await OrtValue.fromList(prep.pixel, [1, 3, _sz, _sz]);
      cleanup.add(px);

      final vOut = await _vision!.run({'pixel_values': px});
      if (vOut.isEmpty) {
        throw StateError('Vision encoder returned no output');
      }
      final vEmb = vOut.values.first;
      debugPrint('[FastVlmService] Vision encode done');

      // 2) Text embedding for the prompt
      debugPrint('[FastVlmService] Text embed start');
      final ids = <int>[_tok.bosId, ..._tok.encode(prompt)];
      final idVal = await OrtValue.fromList(Int64List.fromList(ids), [
        1,
        ids.length,
      ]);
      cleanup.add(idVal);

      final tOut = await _embed!.run({'input_ids': idVal});
      if (tOut.isEmpty) {
        throw StateError('Text embedder returned no output');
      }
      final tEmb = tOut.values.first;
      debugPrint('[FastVlmService] Text embed done');

      // 3) Concatenate embeddings (vision + text)
      debugPrint('[FastVlmService] Concat embeddings start');
      final cmb = await _concatEmbeds(vEmb, tEmb);
      debugPrint(
        '[FastVlmService] Concat embeddings done, seq_len=${cmb.sl}, hidden=${cmb.hs}',
      );

      // 4) Decode loop
      debugPrint('[FastVlmService] Decode loop start');
      final generated = await _decodeLoop(cmb, maxNewTokens: maxNewTokens);
      debugPrint(
        '[FastVlmService] Decode loop done, tokens=${generated.length}',
      );

      // Cleanup intermediate maps after successful decode
      await _disposeAll(cleanup);
      await _disposeMap(vOut);
      await _disposeMap(tOut);

      final text = _tok.decode(generated);
      final dt = DateTime.now().difference(t0).inMilliseconds;
      debugPrint(
        '[FastVlmService] describeCameraImage done in ${dt}ms. Output="$text"',
      );
      return text;
    } catch (e) {
      debugPrint('[FastVlmService] describeCameraImage error: $e');
      await _disposeAll(cleanup);
      rethrow;
    }
  }

  /// Prefill followed by token-by-token generation. High-level logging only.
  Future<List<int>> _decodeLoop(_Cmb cmb, {required int maxNewTokens}) async {
    final outTokens = <int>[];
    final cleanup = <OrtValue>[];
    Map<String, OrtValue>? currentState;

    try {
      // Prefill with embeddings and optional masks and empty kv cache.
      final prefillInputs = await _buildPrefillInputs(cmb, cleanup);
      debugPrint('[FastVlmService] Decoder prefill run start');
      var out = await _dec!.run(prefillInputs);
      debugPrint('[FastVlmService] Decoder prefill run done');

      final logits0 = out[_logitsKey];
      if (logits0 == null) {
        await _disposeMap(out);
        return outTokens;
      }

      var nextId = await _argmaxLastLogit(logits0);
      if (nextId == _tok.eosId) {
        await _disposeMap(out);
        return outTokens;
      }
      outTokens.add(nextId);

      // Extract kv-cache state to feed next step
      currentState = _extractState(out);
      await _disposeNonState(out, currentState);
      await _disposeAll(cleanup);

      // Step generation loop
      for (int t = 0; t < maxNewTokens; t++) {
        final stepInputs = await _buildStepInputs(
          nextId,
          cmb.sl + t,
          currentState,
          cleanup,
        );

        // High-level per-step log only
        debugPrint('[FastVlmService] Decode step $t run');
        out = await _dec!.run(stepInputs);

        final logits = out[_logitsKey];
        if (logits == null) {
          await _disposeMap(out);
          break;
        }

        nextId = await _argmaxLastLogit(logits);
        if (nextId == _tok.eosId) {
          await _disposeMap(out);
          break;
        }
        outTokens.add(nextId);

        // Update kv-cache state
        final newState = _extractState(out);
        await _disposeNonState(out, newState);
        await _disposeMap(currentState);
        currentState = newState;

        await _disposeAll(cleanup);
      }

      return outTokens;
    } catch (e, st) {
      debugPrint('[FastVlmService] _decodeLoop error: $e\n$st');
      rethrow;
    } finally {
      await _disposeMap(currentState);
      await _disposeAll(cleanup);
    }
  }

  /// Build decoder prefill inputs. Must include inputs_embeds for models expecting it.
  Future<Map<String, OrtValue>> _buildPrefillInputs(
    _Cmb cmb,
    List<OrtValue> cleanup,
  ) async {
    final m = <String, OrtValue>{};

    // Required by this model family: embeddings of vision+prompt
    final embedsVal = await OrtValue.fromList(cmb.data, [1, cmb.sl, cmb.hs]);
    m['inputs_embeds'] = embedsVal;
    cleanup.add(embedsVal);

    if (_hasAttentionMask) {
      final am = Int64List(cmb.sl)..fillRange(0, cmb.sl, 1);
      final amVal = await OrtValue.fromList(am, [1, cmb.sl]);
      m['attention_mask'] = amVal;
      cleanup.add(amVal);
    }

    if (_hasPositionIds) {
      final pos = Int64List.fromList(List<int>.generate(cmb.sl, (i) => i));
      final posVal = await OrtValue.fromList(pos, [1, cmb.sl]);
      m['position_ids'] = posVal;
      cleanup.add(posVal);
    }

    // Some decoder exports require empty past_key_values at prefill
    if (_pastKeyNames.isNotEmpty) {
      for (final name in _pastKeyNames) {
        final emptyVal = await OrtValue.fromList(
          Float32List(0),
          [1, 2, 0, 64], // [batch, heads, seq_len=0, head_dim]
        );
        m[name] = emptyVal;
        cleanup.add(emptyVal);
      }
    }

    return m;
  }

  /// Build single-step decoder inputs using last token and kv-cache state.
  Future<Map<String, OrtValue>> _buildStepInputs(
    int tokenId,
    int position,
    Map<String, OrtValue>? state,
    List<OrtValue> cleanup,
  ) async {
    final m = <String, OrtValue>{};

    if (_hasInputIds) {
      final idVal = await OrtValue.fromList(Int64List.fromList([tokenId]), [
        1,
        1,
      ]);
      m['input_ids'] = idVal;
      cleanup.add(idVal);
    }

    if (_hasAttentionMask) {
      final amVal = await OrtValue.fromList(Int64List.fromList([1]), [1, 1]);
      m['attention_mask'] = amVal;
      cleanup.add(amVal);
    }

    if (_hasPositionIds) {
      final posVal = await OrtValue.fromList(Int64List.fromList([position]), [
        1,
        1,
      ]);
      m['position_ids'] = posVal;
      cleanup.add(posVal);
    }

    // Map present.* outputs back to past_key_values.* inputs
    if (state != null && state.isNotEmpty) {
      for (final entry in state.entries) {
        final inputName = entry.key.replaceFirst('present', 'past_key_values');
        m[inputName] = entry.value;
      }
    }

    return m;
  }

  /// Extract decoder state (kv-cache) from outputs for reuse in next step.
  Map<String, OrtValue>? _extractState(Map<String, OrtValue> out) {
    if (_stateKeys.isEmpty) return null;
    final m = <String, OrtValue>{};
    for (final k in _stateKeys) {
      final v = out[k];
      if (v != null) m[k] = v;
    }
    return m.isEmpty ? null : m;
  }

  /// Dispose outputs that are not part of kv-cache state.
  Future<void> _disposeNonState(
    Map<String, OrtValue> out,
    Map<String, OrtValue>? state,
  ) async {
    final toDispose = <OrtValue>[];
    for (final e in out.entries) {
      if (state == null || !state.containsKey(e.key)) {
        toDispose.add(e.value);
      }
    }
    await _disposeAll(toDispose);
  }

  /// Concatenate vision and text embeddings along sequence dimension.
  Future<_Cmb> _concatEmbeds(OrtValue v, OrtValue t) async {
    final vs = v.shape;
    final ts = t.shape;
    if (vs == null || ts == null || vs.length < 3 || ts.length < 3) {
      throw StateError('Invalid embedding shapes');
    }

    final vfList = await v.asFlattenedList();
    final tfList = await t.asFlattenedList();

    final totalLen = vfList.length + tfList.length;
    final out = Float32List(totalLen);

    // Copy vision embeddings
    for (int i = 0; i < vfList.length; i++) {
      out[i] = (vfList[i] as num).toDouble();
    }
    // Copy text embeddings
    for (int i = 0; i < tfList.length; i++) {
      out[vfList.length + i] = (tfList[i] as num).toDouble();
    }

    // seq_len = vs[1] + ts[1], hidden_size = vs[2] (must match)
    return _Cmb(out, vs[1] + ts[1], vs[2]);
  }

  /// Argmax over the last time step of logits.
  Future<int> _argmaxLastLogit(OrtValue logits) async {
    final s = logits.shape;
    if (s == null || s.length < 2) {
      throw StateError('Invalid logits shape');
    }
    final V = s.last;
    final raw = await logits.asFlattenedList();
    final start = (s[s.length - 2] - 1) * V;

    int argmax = 0;
    double maxVal = double.negativeInfinity;
    for (int i = 0; i < V; i++) {
      final v = (raw[start + i] as num).toDouble();
      if (v > maxVal) {
        maxVal = v;
        argmax = i;
      }
    }
    return argmax;
  }

  /// Dispose a list of OrtValue safely.
  Future<void> _disposeAll(List<OrtValue> values) async {
    if (values.isEmpty) return;
    await Future.wait(
      values.map((v) => v.dispose().catchError((_) {})),
      eagerError: false,
    );
    values.clear();
  }

  /// Dispose all values contained in a map.
  Future<void> _disposeMap(Map<String, OrtValue>? m) async {
    if (m == null || m.isEmpty) return;
    await _disposeAll(m.values.toList());
  }

  /// Close all sessions.
  Future<void> dispose() async {
    debugPrint('[FastVlmService] Disposing sessions');
    await Future.wait([
      if (_vision != null) _vision!.close().catchError((_) {}),
      if (_embed != null) _embed!.close().catchError((_) {}),
      if (_dec != null) _dec!.close().catchError((_) {}),
    ]);
    _vision = _embed = _dec = null;
    debugPrint('[FastVlmService] Disposed');
  }
}

// ===== Preprocessing isolate structs and functions =====

class _Pack {
  final int w, h, target, yrs, urs, ups;
  final Uint8List y, u, v;
  final List<double> mean, invStd;

  _Pack(
    this.w,
    this.h,
    this.target,
    this.yrs,
    this.urs,
    this.ups,
    this.y,
    this.u,
    this.v,
    this.mean,
    this.invStd,
  );

  factory _Pack.fromCamera(
    CameraImage im,
    int target,
    List<double> mean,
    List<double> invStd,
  ) {
    return _Pack(
      im.width,
      im.height,
      target,
      im.planes[0].bytesPerRow,
      im.planes[1].bytesPerRow,
      im.planes[1].bytesPerPixel!,
      im.planes[0].bytes,
      im.planes[1].bytes,
      im.planes[2].bytes,
      mean,
      invStd,
    );
  }
}

class _PrepOut {
  final Float32List pixel;
  _PrepOut(this.pixel);
}

/// Convert YUV420 camera frame to normalized CHW float tensor.
/// Runs in an isolate to reduce UI thread work.
_PrepOut _preprocess(_Pack p) {
  final w = p.w, h = p.h, t = p.target;

  // Convert to packed RGB
  final rgbBytes = Uint8List(w * h * 3);
  int idx = 0;

  for (int r = 0; r < h; r++) {
    final yOff = r * p.yrs;
    final uvRow = (r >> 1) * p.urs;

    for (int c = 0; c < w; c++) {
      final uvCol = (c >> 1) * p.ups;

      final Y = p.y[yOff + c];
      final U = p.u[uvRow + uvCol] - FastVlmService._uvCenter;
      final V = p.v[uvRow + uvCol] - FastVlmService._uvCenter;

      final rV = _clamp(
        Y + ((V * FastVlmService._yuvRCoeffV) >> FastVlmService._yuvShift),
      );
      final gV = _clamp(
        Y -
            ((U * FastVlmService._yuvGCoeffU +
                    V * FastVlmService._yuvGCoeffV) >>
                FastVlmService._yuvShift),
      );
      final bV = _clamp(
        Y + ((U * FastVlmService._yuvBCoeffU) >> FastVlmService._yuvShift),
      );

      rgbBytes[idx++] = rV;
      rgbBytes[idx++] = gV;
      rgbBytes[idx++] = bV;
    }
  }

  // Build image then resize to model input
  final imgRGB = img.Image.fromBytes(
    width: w,
    height: h,
    bytes: rgbBytes.buffer,
    numChannels: 3,
  );

  final resized = img.copyResize(
    imgRGB,
    width: t,
    height: t,
    interpolation: img.Interpolation.linear,
  );

  // Normalize to CHW
  final plane = t * t;
  final out = Float32List(3 * plane);
  int pi = 0;

  for (final px in resized) {
    out[pi] = (px.rNormalized - p.mean[0]) * p.invStd[0];
    out[pi + plane] = (px.gNormalized - p.mean[1]) * p.invStd[1];
    out[pi + 2 * plane] = (px.bNormalized - p.mean[2]) * p.invStd[2];
    pi++;
  }

  return _PrepOut(out);
}

@pragma('vm:prefer-inline')
int _clamp(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

// ===== Simple embedding container =====

class _Cmb {
  final Float32List data;
  final int sl; // sequence length
  final int hs; // hidden size

  _Cmb(this.data, this.sl, this.hs);
}
