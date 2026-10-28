import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../models/depth_analysis.dart';
import '../models/detection.dart';
import '../models/scene_analysis.dart';
import '../models/segmentation_result.dart';
import '../utils/coco_labels.dart';
import '../utils/oiv7_labels.dart';
import 'camera_intrinsics.dart';
import 'depth_estimator.dart';
import 'distance_estimator.dart';
import 'segmentation_service.dart';
import 'yolo_detector.dart';

enum ModelChoice { coco80, oiv7, doorOnly }

/// Change this ONE line to switch the active model.
///   coco80   = 80-class COCO YOLO11n (no doors)
///   oiv7     = 600-class Open Images V7 (has doors, curtains, fridge etc.)
///   doorOnly = your specialist door model
const ModelChoice activeModel = ModelChoice.coco80;

/// Phase 2: MiDaS depth. Flip to false to disable depth quickly without
/// removing the model file.
const bool useDepth = true;

/// Phase 3: DeepLab segmentation. OFF by default — Cityscapes is trained on
/// European street scenes and the result on Nepali roads/indoors will be
/// wrong more often than right. Flip to true when ready to test outdoors.
const bool useSegmentation = true;

/// Phase 5: MiDaS scale-shift fusion for distance estimation.
///
/// When true, we use reliable-prior detections (person, laptop, bottle,
/// stop sign etc.) as "anchor points" to solve a 2-parameter linear fit
/// between MiDaS raw inverse depth and metric distance. Then we apply
/// that fit to ALL detections — including the loose-prior ones like
/// suitcase, backpack, bus, truck, where the per-class size assumption
/// fails badly.
///
/// Why this fixes the suitcase problem:
///   * Pinhole assumes suitcase = 0.55m tall (carry-on).
///   * A 0.95m trolley at 2.4m looks like a 0.55m carry-on at 1.4m.
///   * MiDaS sees it's actually further away than pinhole says.
///   * Fusion uses MiDaS depth to correct, anchored by other objects
///     in the same frame whose size we DO know reliably.
///
/// Falls back to pinhole if <2 reliable anchors are present in frame
/// (the fit needs at least 2 data points). When that happens the
/// loose-prior gating below kicks in to avoid speaking false numbers.
const bool useMidasFusion = true;

/// Classes whose per-class size prior is loose enough that we should
/// NOT speak metre values without MiDaS correction. They will still
/// have distance computed (for ranking by closeness), but the
/// `distanceSource` will be marked 'unreliable' and the UI / scene
/// describer can choose to suppress the number.
///
/// Driven by `ObjectPrior.reliable == false` in coco_labels.dart, but
/// listed explicitly here so it's obvious from the inference pipeline.
/// If you add new priors, mark them reliable=true only when the size
/// variation across instances is <±25%.
const Set<String> _loosePriorClasses = <String>{
  'suitcase', 'backpack', 'handbag', 'umbrella',
  'book', 'cup', 'bowl', 'wine glass',
  'bus', 'truck', 'motorcycle', 'bicycle',
  'cat', 'dog', 'potted plant',
  'couch', 'bed', 'dining table',
  'cell phone', 'remote', 'keyboard', 'mouse',
  'sink', 'clock', 'vase',
  'traffic light', 'parking meter',
  'teddy bear', 'toaster',
};

/// Asset path for the MiDaS small TFLite model.
const String _midasAsset = 'assets/midas_v2_1_small_int8_256.tflite';

/// Asset path for the DeepLabV3 Cityscapes int8 TFLite model.
const String _deeplabAsset = 'assets/deeplabv3_pascal_voc_257.tflite';

String _assetForModel(ModelChoice m) {
  switch (m) {
    case ModelChoice.coco80:
      return 'assets/yolo11n_int8_320.tflite';
    case ModelChoice.oiv7:
      return 'assets/yolov8n_oiv7_int8_320.tflite';
    case ModelChoice.doorOnly:
      return 'assets/door_yolov8_float16_320.tflite';
  }
}

LabelSet _labelSetFor(ModelChoice m) {
  switch (m) {
    case ModelChoice.coco80:
      return LabelSet.coco80;
    case ModelChoice.oiv7:
      return LabelSet.oiv7;
    case ModelChoice.doorOnly:
      return LabelSet.doorOnly;
  }
}

class _Req {
  final int id;
  final Uint8List jpegBytes;
  final CameraIntrinsics cam;
  _Req(this.id, this.jpegBytes, this.cam);
}

class _InitMsg {
  final SendPort replyTo;
  final int yoloAddr;
  final int? midasAddr; // null if depth disabled or failed to load
  final int? segAddr;   // null if segmentation disabled or failed to load
  final RootIsolateToken token;
  final ModelChoice model;
  _InitMsg(
    this.replyTo,
    this.yoloAddr,
    this.midasAddr,
    this.segAddr,
    this.token,
    this.model,
  );
}

class IsolateInference {
  SendPort? _sendPort;
  Isolate? _iso;
  final ReceivePort _mainPort = ReceivePort();
  int _nextId = 0;
  final Map<int, Completer<SceneAnalysis>> _pending = {};

  late Interpreter _yoloInterp;
  Interpreter? _midasInterp; // null if depth disabled or failed to load
  Interpreter? _segInterp;   // null if segmentation disabled or failed to load

  Future<void> start() async {
    // ignore: avoid_print
    print('[IsolateInference] start() begin, '
        'useDepth=$useDepth useSegmentation=$useSegmentation '
        'useMidasFusion=$useMidasFusion');

    _yoloInterp = await Interpreter.fromAsset(
      _assetForModel(activeModel),
      options: InterpreterOptions()..threads = 4,
    );

    if (useDepth) {
      try {
        // ignore: avoid_print
        print('[IsolateInference] starting MiDaS load from $_midasAsset');
        _midasInterp = await Interpreter.fromAsset(
          _midasAsset,
          options: InterpreterOptions()..threads = 2,
        );
        final inShape = _midasInterp!.getInputTensor(0).shape;
        final outShape = _midasInterp!.getOutputTensor(0).shape;
        // ignore: avoid_print
        print('[IsolateInference] MiDaS loaded; in=$inShape out=$outShape '
            'addr=${_midasInterp!.address}');
      } catch (e, st) {
        // ignore: avoid_print
        print('[IsolateInference] MiDaS load FAILED: $e\n$st');
        _midasInterp = null;
      }
    } else {
      // ignore: avoid_print
      print('[IsolateInference] depth disabled by useDepth flag');
    }

    if (useSegmentation) {
      try {
        // ignore: avoid_print
        print('[IsolateInference] starting DeepLab load from $_deeplabAsset');
        _segInterp = await Interpreter.fromAsset(
          _deeplabAsset,
          options: InterpreterOptions()..threads = 2,
        );
        final inShape = _segInterp!.getInputTensor(0).shape;
        final outShape = _segInterp!.getOutputTensor(0).shape;
        // ignore: avoid_print
        print('[IsolateInference] DeepLab loaded; in=$inShape out=$outShape '
            'addr=${_segInterp!.address}');
      } catch (e, st) {
        // ignore: avoid_print
        print('[IsolateInference] DeepLab load FAILED: $e\n$st');
        _segInterp = null;
      }
    } else {
      // ignore: avoid_print
      print('[IsolateInference] segmentation disabled by useSegmentation flag');
    }

    _mainPort.listen(_onMain);

    _iso = await Isolate.spawn<_InitMsg>(
      _entry,
      _InitMsg(
        _mainPort.sendPort,
        _yoloInterp.address,
        _midasInterp?.address,
        _segInterp?.address,
        RootIsolateToken.instance!,
        activeModel,
      ),
    );
  }

  void _onMain(dynamic msg) {
    if (msg is SendPort) {
      _sendPort = msg;
      return;
    }
    if (msg is Map && msg['type'] == 'result') {
      final id = msg['id'] as int;
      _pending.remove(id)?.complete(msg['data'] as SceneAnalysis);
    } else if (msg is Map && msg['type'] == 'error') {
      final id = msg['id'] as int;
      _pending.remove(id)?.completeError(msg['error'] as Object);
    }
  }

  Future<SceneAnalysis> analyseJpeg({
    required Uint8List jpegBytes,
    required CameraIntrinsics intrinsics,
  }) async {
    if (_sendPort == null) {
      throw StateError('Isolate not started');
    }
    final id = _nextId++;
    final c = Completer<SceneAnalysis>();
    _pending[id] = c;
    _sendPort!.send(_Req(id, jpegBytes, intrinsics));
    return c.future;
  }

  Future<void> stop() async {
    _iso?.kill(priority: Isolate.immediate);
    _iso = null;
    _yoloInterp.close();
    _midasInterp?.close();
    _midasInterp = null;
    _segInterp?.close();
    _segInterp = null;
    _mainPort.close();
  }

  static Future<void> _entry(_InitMsg init) async {
    BackgroundIsolateBinaryMessenger.ensureInitialized(init.token);

    final yolo = YoloDetector(
      Interpreter.fromAddress(init.yoloAddr),
      labelSet: _labelSetFor(init.model),
    );

    DepthEstimator? depth;
    // ignore: avoid_print
    print('[isolate] _entry begin, midasAddr=${init.midasAddr}');
    if (init.midasAddr != null) {
      try {
        depth = DepthEstimator()..loadFromAddress(init.midasAddr!);
        // ignore: avoid_print
        print('[isolate] depth init ok');
      } catch (e, st) {
        // ignore: avoid_print
        print('[isolate] depth init FAILED, continuing YOLO-only: $e\n$st');
        depth = null;
      }
    } else {
      // ignore: avoid_print
      print('[isolate] depth skipped (midasAddr is null)');
    }

    SegmentationService? seg;
    // ignore: avoid_print
    print('[isolate] _entry segAddr=${init.segAddr}');
    if (init.segAddr != null) {
      try {
        seg = SegmentationService()..loadFromAddress(init.segAddr!);
        // ignore: avoid_print
        print('[isolate] segmentation init ok');
      } catch (e, st) {
        // ignore: avoid_print
        print('[isolate] segmentation init FAILED: $e\n$st');
        seg = null;
      }
    } else {
      // ignore: avoid_print
      print('[isolate] segmentation skipped (segAddr is null)');
    }

    final rp = ReceivePort();
    init.replyTo.send(rp.sendPort);

    await for (final dynamic msg in rp) {
      if (msg is _Req) {
        final sw = Stopwatch()..start();
        try {
          final decoded = img.decodeImage(msg.jpegBytes);
          if (decoded == null) throw 'jpeg decode failed';

          final rawDets = yolo.detect(decoded);
          sw.stop();
          final yoloMs = sw.elapsedMilliseconds;

          // ---- Phase 2: MiDaS depth (best-effort, never blocks YOLO result)
          DepthAnalysis? depthAnalysis;
          int? depthMs;
          if (depth != null) {
            final dsw = Stopwatch()..start();
            try {
              depthAnalysis = depth.analyze(decoded);
              dsw.stop();
              depthMs = dsw.elapsedMilliseconds;
              if (depthAnalysis != null) {
                // ignore: avoid_print
                print('[isolate] depth ok ${depthMs}ms '
                    'L=${depthAnalysis.left.zone.name}/'
                    '${depthAnalysis.left.normalizedClosest.toStringAsFixed(2)} '
                    'C=${depthAnalysis.center.zone.name}/'
                    '${depthAnalysis.center.normalizedClosest.toStringAsFixed(2)} '
                    'R=${depthAnalysis.right.zone.name}/'
                    '${depthAnalysis.right.normalizedClosest.toStringAsFixed(2)}');
              } else {
                // ignore: avoid_print
                print('[isolate] depth.analyze returned null');
              }
            } catch (e, st) {
              dsw.stop();
              // ignore: avoid_print
              print('[isolate] depth analyze FAILED: $e\n$st');
              depthAnalysis = null;
              depthMs = null;
            }
          } else {
            // ignore: avoid_print
            print('[isolate] depth not available for this frame');
          }

          // ---- Phase 5: distance estimation
          //
          // Two paths:
          //   A) MiDaS fusion ON + we have a depth map + ≥2 reliable
          //      anchors → use fuseDistances() to get per-detection
          //      metric distance corrected by MiDaS.
          //   B) Otherwise → pinhole-only with loose-prior gating.
          //
          // The MiDaS fusion path requires sampling the median raw
          // depth value inside each detection's bounding box. That's
          // computed inline below from `depth.lastRawMap` (the
          // unscaled MiDaS output cached during analyze()).
          //
          // If anything is missing (depth map unavailable, MiDaS
          // sampling failed, <2 anchors), we silently fall back to
          // path B. The fallback is logged so a failed fusion doesn't
          // hide behind a working pipeline.
          final List<Detection> withDistance = <Detection>[];
          double? scaleS;
          double? scaleT;

          // ---- Compute pinhole distance for every detection (we
          // need this either way — as the "anchor" for fusion, or as
          // the final answer if fusion is unavailable).
          final pinholeZ = <double>[];
          final pinholeAxis = <String>[];
          final pinholeDim = <double>[];
          for (final d in rawDets) {
            double z = double.nan;
            String axis = 'h';
            double dim = 0;

            if (init.model == ModelChoice.doorOnly) {
              dim = 2.0;
              axis = 'h';
            } else if (init.model == ModelChoice.oiv7) {
              final p = oiv7Priors[d.label];
              if (p != null) { dim = p.dim; axis = p.axis; }
            } else {
              final p = cocoObjectPriors[d.label];
              if (p != null) { dim = p.dim; axis = p.axis; }
            }

            if (dim > 0) {
              if (axis == 'h' && d.height > 0) {
                z = dim * msg.cam.fyPixels / d.height;
              } else if (axis == 'w' && d.width > 0) {
                z = dim * msg.cam.fxPixels / d.width;
              }
              if (z.isFinite) {
                if (z < 0.15) z = 0.15;
                if (z > 20.0) z = 20.0;
              }
            }

            pinholeZ.add(z);
            pinholeAxis.add(axis);
            pinholeDim.add(dim);
          }

          // ---- Try MiDaS fusion if available
          List<double>? midasMedians;
          if (useMidasFusion && depth != null && depthAnalysis != null) {
            try {
              midasMedians = _sampleMidasMedians(depth, rawDets, decoded);
              // ignore: avoid_print
              print('[isolate] midas medians sampled: '
                  'count=${midasMedians.length} '
                  'finite=${midasMedians.where((m) => !m.isNaN).length}');
            } catch (e) {
              // ignore: avoid_print
              print('[isolate] midas median sampling FAILED, '
                  'fallback to pinhole-only: $e');
              midasMedians = null;
            }
          }

          if (useMidasFusion &&
              midasMedians != null &&
              midasMedians.length == rawDets.length) {
            final hybrid = fuseDistances(
              rawDets,
              midasMedians,
              msg.cam,
            );

            if (hybrid.ss != null) {
              scaleS = hybrid.ss!.s;
              scaleT = hybrid.ss!.t;
              // ignore: avoid_print
              print('[isolate] MiDaS fusion ACTIVE: '
                  's=${scaleS!.toStringAsFixed(4)} '
                  't=${scaleT!.toStringAsFixed(4)} '
                  '— suitcase/bus/truck distances now MiDaS-corrected');
            } else {
              // ignore: avoid_print
              print('[isolate] MiDaS fusion: <2 reliable anchors in frame, '
                  'falling back to pinhole-only with loose-prior gating');
            }

            // Use fused detections, but mark loose-prior classes whose
            // distance came from pinhole-only (no MiDaS correction
            // because fit failed) as 'unreliable'.
            for (int i = 0; i < hybrid.detections.length; i++) {
              final d = hybrid.detections[i];
              String src = d.distanceSource;
              double z = d.distanceMeters;

              // If fit failed (no scale-shift solved) and this is a
              // loose-prior class, downgrade the source so the UI
              // can suppress speaking the false number.
              if (hybrid.ss == null &&
                  _loosePriorClasses.contains(d.label) &&
                  src == 'pinhole') {
                src = 'unreliable';
              }

              if (rawDets[i].touchesEdge && src == 'pinhole') {
                src = 'pinhole-clipped';
              }

              withDistance.add(Detection(
                classId: d.classId,
                label: d.label,
                confidence: d.confidence,
                x1: d.x1, y1: d.y1, x2: d.x2, y2: d.y2,
                distanceMeters: z,
                distanceSource: src,
                touchesEdge: rawDets[i].touchesEdge,
              ));
            }
          } else {
            // ---- Fallback: pinhole-only with loose-prior gating
            for (int i = 0; i < rawDets.length; i++) {
              final d = rawDets[i];
              double z = pinholeZ[i];
              String src;

              if (pinholeDim[i] <= 0) {
                src = 'category-only';
              } else if (!z.isFinite) {
                src = 'none';
              } else if (_loosePriorClasses.contains(d.label)) {
                // Honest mode: distance is computed (so we can rank
                // by closeness for "closest first" announcements) but
                // marked unreliable so the scene describer / UI can
                // choose to omit the number.
                src = 'unreliable';
              } else if (d.touchesEdge) {
                src = 'pinhole-clipped';
              } else {
                src = 'pinhole';
              }

              withDistance.add(Detection(
                classId: d.classId,
                label: d.label,
                confidence: d.confidence,
                x1: d.x1, y1: d.y1, x2: d.x2, y2: d.y2,
                distanceMeters: z,
                distanceSource: src,
                touchesEdge: d.touchesEdge,
              ));
            }
          }

          // ---- Phase 3: DeepLab segmentation (best-effort)
          PathAnalysis? pathAnalysis;
          int? segMs;
          if (seg != null) {
            final ssw = Stopwatch()..start();
            try {
              pathAnalysis = seg.analyze(decoded);
              ssw.stop();
              segMs = ssw.elapsedMilliseconds;
              if (pathAnalysis != null) {
                // ignore: avoid_print
                print('[isolate] segmentation ok ${segMs}ms '
                    'walkable L=${pathAnalysis.leftWalkable.toStringAsFixed(2)} '
                    'C=${pathAnalysis.centerWalkable.toStringAsFixed(2)} '
                    'R=${pathAnalysis.rightWalkable.toStringAsFixed(2)} '
                    'dir=${pathAnalysis.recommendedDirection.name} '
                    'sidewalk=${pathAnalysis.sidewalkVisible} '
                    'road=${pathAnalysis.roadVisible} '
                    'vehicle=${pathAnalysis.vehicleVisible}');
              } else {
                // ignore: avoid_print
                print('[isolate] segmentation.analyze returned null');
              }
            } catch (e, st) {
              ssw.stop();
              // ignore: avoid_print
              print('[isolate] segmentation analyze FAILED: $e\n$st');
              pathAnalysis = null;
              segMs = null;
            }
          }

          init.replyTo.send(<String, dynamic>{
            'type': 'result',
            'id': msg.id,
            'data': SceneAnalysis(
              imageWidth: decoded.width,
              imageHeight: decoded.height,
              detections: withDistance,
              latencyMs: yoloMs,
              scaleShiftS: scaleS,
              scaleShiftT: scaleT,
              depth: depthAnalysis,
              depthLatencyMs: depthMs,
              path: pathAnalysis,
              segLatencyMs: segMs,
            ),
          });
        } catch (e) {
          init.replyTo.send(<String, dynamic>{
            'type': 'error',
            'id': msg.id,
            'error': '$e',
          });
        }
      }
    }
  }

  /// Sample the median raw MiDaS value within each detection's
  /// bounding box. Returns one value per detection; NaN means the
  /// box was empty / out of bounds / depth map unavailable.
  ///
  /// We use the median (not mean) because MiDaS depth maps have
  /// occasional outlier pixels at object edges that would skew a
  /// mean badly. The median is robust to those edge artefacts.
  ///
  /// This is a minimal implementation that assumes DepthEstimator
  /// caches its raw output as `lastRawMap` (a flat List<double> of
  /// size width*height). If your DepthEstimator doesn't expose this
  /// yet, see the integration note in the chat — you'll need a 1-line
  /// addition to depth_estimator.dart.
  static List<double> _sampleMidasMedians(
    DepthEstimator depth,
    List<Detection> dets,
    img.Image originalImage,
  ) {
    final raw = depth.lastRawMap;
    final mapW = depth.lastMapWidth;
    final mapH = depth.lastMapHeight;
    if (raw == null || mapW == null || mapH == null) {
      // ignore: avoid_print
      print('[isolate] _sampleMidasMedians: depth map not cached');
      return List<double>.filled(dets.length, double.nan);
    }

    final imgW = originalImage.width;
    final imgH = originalImage.height;
    final out = <double>[];

    for (final d in dets) {
      // Map detection bbox (in original-image coords) into MiDaS map coords.
      final mx1 = ((d.x1 / imgW) * mapW).clamp(0.0, mapW - 1.0).toInt();
      final my1 = ((d.y1 / imgH) * mapH).clamp(0.0, mapH - 1.0).toInt();
      final mx2 = ((d.x2 / imgW) * mapW).clamp(0.0, mapW - 1.0).toInt();
      final my2 = ((d.y2 / imgH) * mapH).clamp(0.0, mapH - 1.0).toInt();

      if (mx2 <= mx1 || my2 <= my1) {
        out.add(double.nan);
        continue;
      }

      // Sample the central 60% of the bbox to avoid edge artefacts.
      final padX = ((mx2 - mx1) * 0.20).round();
      final padY = ((my2 - my1) * 0.20).round();
      final sx1 = mx1 + padX, sx2 = mx2 - padX;
      final sy1 = my1 + padY, sy2 = my2 - padY;

      final values = <double>[];
      for (int y = sy1; y < sy2; y++) {
        for (int x = sx1; x < sx2; x++) {
          final v = raw[y * mapW + x];
          if (v.isFinite) values.add(v);
        }
      }

      if (values.isEmpty) {
        out.add(double.nan);
        continue;
      }
      values.sort();
      out.add(values[values.length ~/ 2]);
    }

    return out;
  }
}