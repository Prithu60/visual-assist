import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../models/detection.dart';
import '../utils/coco_labels.dart';
import '../utils/oiv7_labels.dart';
import 'image_preprocessor.dart';

enum LabelSet { coco80, oiv7, doorOnly }

/// YOLO TFLite detector with FULL DIAGNOSTIC LOGGING.
///
/// Why this version exists:
///   The door-only model returned KEPT=0 with no info on why.
///   This version prints the maxScore across all anchors, anchor
///   distribution at score thresholds, the top 3 raw boxes, and a
///   reason for every rejection. After one capture you'll know
///   exactly which filter is silently dropping detections.
///
/// Door-only thresholds dropped:
///   confThreshold: 0.35 -> 0.10
///   minAreaFrac:   0.005 -> 0.001
///   floor:         0.35 -> 0.05
class YoloDetector {
  static const int inputSize = 320;
  static const double nmsThreshold = 0.30;
  static const double crossClassNmsThreshold = 0.60;
  static const double edgeTolerance = 0.02;

  final Interpreter interpreter;
  final LabelSet labelSet;

  late final List<int> _inShape;
  late final List<int> _outShape;
  late final TensorType _inType;
  late final TensorType _outType;
  late final double _outScale;
  late final int _outZeroPoint;
  late final int _numClasses;

  YoloDetector(this.interpreter, {this.labelSet = LabelSet.coco80}) {
    final inT = interpreter.getInputTensor(0);
    final outT = interpreter.getOutputTensor(0);

    _inShape = inT.shape;
    _outShape = outT.shape;
    _inType = inT.type;
    _outType = outT.type;
    _outScale = outT.params.scale;
    _outZeroPoint = outT.params.zeroPoint;

    _numClasses = _outShape[1] - 4;

    // ignore: avoid_print
    print('=== YOLO MODEL LOADED ===');
    // ignore: avoid_print
    print('  IN  shape=$_inShape  type=$_inType');
    // ignore: avoid_print
    print('  OUT shape=$_outShape  type=$_outType  classes=$_numClasses');
    // ignore: avoid_print
    print('  LabelSet: $labelSet');
  }

  String _labelFor(int cls) {
    if (labelSet == LabelSet.doorOnly) return 'door';
    if (labelSet == LabelSet.oiv7) {
      if (cls < 0 || cls >= oiv7Labels.length) return 'unknown';
      return oiv7Labels[cls];
    }
    if (cls < 0 || cls >= cocoLabels.length) return 'unknown';
    return cocoLabels[cls];
  }

  bool _isIgnored(String label) {
    if (labelSet == LabelSet.doorOnly) return false;
    if (labelSet == LabelSet.oiv7) return !oiv7AllowedLabels.contains(label);
    return ignoredLabels.contains(label);
  }

  double _confThreshold(String label) {
    if (labelSet == LabelSet.doorOnly) return 0.10;
    if (labelSet == LabelSet.oiv7) {
      return oiv7PerClassConf[label] ?? defaultOiv7ConfThreshold;
    }
    return perClassConfThreshold[label] ?? defaultConfThreshold;
  }

  double _minAreaFrac(String label) {
    if (labelSet == LabelSet.doorOnly) return 0.001;
    if (labelSet == LabelSet.oiv7) {
      return oiv7PerClassMinArea[label] ?? defaultOiv7MinAreaFrac;
    }
    return perClassMinAreaFrac[label] ?? defaultMinAreaFrac;
  }

  static const Map<String, String> _canonicalGroup = {
    'Person': 'person', 'Man': 'person', 'Woman': 'person',
    'Boy': 'person', 'Girl': 'person',
    'Human body': 'person', 'Human head': 'person', 'Human face': 'person',
    'Sofa bed': 'sofa', 'Couch': 'sofa', 'Loveseat': 'sofa',
    'Kitchen & dining room table': 'table', 'Coffee table': 'table',
    'Desk': 'table', 'Table': 'table',
    'Mobile phone': 'phone', 'Corded phone': 'phone', 'Telephone': 'phone',
    'Suitcase': 'bag', 'Backpack': 'bag', 'Handbag': 'bag',
    'Briefcase': 'bag', 'Luggage and bags': 'bag',
  };

  String _canonical(String label) => _canonicalGroup[label] ?? label;

  List<Detection> detect(img.Image originalImage) {
    final lb = letterbox(originalImage, inputSize);

    Object input;
    if (_inType == TensorType.uint8) {
      final buf = Uint8List(inputSize * inputSize * 3);
      int o = 0;
      for (int y = 0; y < inputSize; y++) {
        for (int x = 0; x < inputSize; x++) {
          final p = lb.image.getPixel(x, y);
          buf[o++] = p.r.toInt();
          buf[o++] = p.g.toInt();
          buf[o++] = p.b.toInt();
        }
      }
      input = buf.reshape(_inShape);
    } else {
      input = List.generate(
        1,
        (_) => List.generate(
          inputSize,
          (y) => List.generate(
            inputSize,
            (x) {
              final p = lb.image.getPixel(x, y);
              return <double>[p.r / 255.0, p.g / 255.0, p.b / 255.0];
            },
          ),
        ),
      );
    }

    Object output;
    if (_outType == TensorType.uint8) {
      final total = _outShape[0] * _outShape[1] * _outShape[2];
      output = Uint8List(total).reshape(_outShape);
    } else {
      output = List.generate(
        _outShape[0],
        (_) => List.generate(
          _outShape[1],
          (_) => List<double>.filled(_outShape[2], 0.0),
        ),
      );
    }

    interpreter.run(input, output);

    final numAnchors = _outShape[2];
    double Function(int c, int i) read;
    if (_outType == TensorType.uint8) {
      final nested = output as List;
      read = (int c, int i) {
        final q = nested[0][c][i] as int;
        return _outScale * (q - _outZeroPoint);
      };
    } else {
      final nested = output as List;
      read = (int c, int i) => nested[0][c][i] as double;
    }

    // ============================================================
    // PASS 1: DIAGNOSTIC SCAN — find max score, count anchors at
    // various thresholds, sample box coords to detect normalization
    // ============================================================
    double maxScoreEver = 0.0;
    int maxScoreClass = 0;
    int maxScoreAnchor = 0;
    int countAbove005 = 0;
    int countAbove010 = 0;
    int countAbove020 = 0;
    int countAbove030 = 0;
    double sumW = 0, sumH = 0;
    int validForAvg = 0;

    for (int i = 0; i < numAnchors; i++) {
      int bestCls = 0;
      double bestScore = 0.0;
      for (int c = 0; c < _numClasses; c++) {
        final s = read(4 + c, i);
        if (s > bestScore) {
          bestScore = s;
          bestCls = c;
        }
      }
      if (bestScore > maxScoreEver) {
        maxScoreEver = bestScore;
        maxScoreClass = bestCls;
        maxScoreAnchor = i;
      }
      if (bestScore >= 0.05) countAbove005++;
      if (bestScore >= 0.10) countAbove010++;
      if (bestScore >= 0.20) countAbove020++;
      if (bestScore >= 0.30) countAbove030++;

      if (bestScore >= 0.05 && validForAvg < 30) {
        sumW += read(2, i);
        sumH += read(3, i);
        validForAvg++;
      }
    }

    // ignore: avoid_print
    print('=== YOLO DIAGNOSTIC ===');
    // ignore: avoid_print
    print('  numAnchors=$numAnchors numClasses=$_numClasses');
    // ignore: avoid_print
    print('  maxScore=${maxScoreEver.toStringAsFixed(4)} '
        '(class=$maxScoreClass=${_labelFor(maxScoreClass)} anchor=$maxScoreAnchor)');
    // ignore: avoid_print
    print('  count >0.05=$countAbove005  >0.10=$countAbove010  '
        '>0.20=$countAbove020  >0.30=$countAbove030');

    // Detect coordinate normalization. Ultralytics YOLO11 TFLite emits
    // normalized coords (0..1); some older exports emit pixel coords (0..320).
    // We detect this by looking at average bbox width/height across high-conf
    // anchors. If avg_w<2.0 -> normalized. If avg_w>5.0 -> pixel.
    bool coordsNormalized = true;
    if (validForAvg > 0) {
      final avgW = sumW / validForAvg;
      final avgH = sumH / validForAvg;
      coordsNormalized = avgW < 2.0 && avgH < 2.0;
      // ignore: avoid_print
      print('  avg bbox over top ${validForAvg} anchors: '
          'w=${avgW.toStringAsFixed(3)} h=${avgH.toStringAsFixed(3)}');
      // ignore: avoid_print
      print('  coordsNormalized=$coordsNormalized '
          '(values <2.0 = normalized, >5.0 = pixel)');
    }
    final double coordScale = coordsNormalized ? inputSize.toDouble() : 1.0;

    // Print the top 3 highest-confidence raw boxes for sanity check.
    final List<int> topAnchors = [];
    final List<double> topScores = [];
    for (int i = 0; i < numAnchors; i++) {
      double bestScore = 0.0;
      for (int c = 0; c < _numClasses; c++) {
        final s = read(4 + c, i);
        if (s > bestScore) bestScore = s;
      }
      if (bestScore < 0.05) continue;
      int insertAt = topScores.length;
      for (int j = 0; j < topScores.length; j++) {
        if (bestScore > topScores[j]) { insertAt = j; break; }
      }
      if (insertAt < 3) {
        topAnchors.insert(insertAt, i);
        topScores.insert(insertAt, bestScore);
        if (topAnchors.length > 3) {
          topAnchors.removeLast();
          topScores.removeLast();
        }
      }
    }
    for (int t = 0; t < topAnchors.length; t++) {
      final i = topAnchors[t];
      int bestCls = 0;
      double bestScore = 0.0;
      for (int c = 0; c < _numClasses; c++) {
        final s = read(4 + c, i);
        if (s > bestScore) { bestScore = s; bestCls = c; }
      }
      // ignore: avoid_print
      print('  TOP[$t] anchor=$i cls=${_labelFor(bestCls)} '
          'score=${bestScore.toStringAsFixed(3)} '
          'raw_cx=${read(0, i).toStringAsFixed(3)} '
          'raw_cy=${read(1, i).toStringAsFixed(3)} '
          'raw_w=${read(2, i).toStringAsFixed(3)} '
          'raw_h=${read(3, i).toStringAsFixed(3)}');
    }

    // ============================================================
    // PASS 2: BUILD DETECTIONS WITH TRACKING OF REJECTION REASONS
    // ============================================================
    final raw = <Detection>[];
    final imageArea = originalImage.width * originalImage.height;

    final double floor = labelSet == LabelSet.doorOnly ? 0.05 : 0.10;

    int rejFloor = 0, rejIgnore = 0, rejClassThresh = 0;

    for (int i = 0; i < numAnchors; i++) {
      int bestCls = 0;
      double bestScore = 0.0;
      for (int c = 0; c < _numClasses; c++) {
        final s = read(4 + c, i);
        if (s > bestScore) { bestScore = s; bestCls = c; }
      }
      if (bestScore < floor) { rejFloor++; continue; }

      final label = _labelFor(bestCls);
      if (_isIgnored(label)) { rejIgnore++; continue; }
      if (bestScore < _confThreshold(label)) { rejClassThresh++; continue; }

      final double cx = read(0, i) * coordScale;
      final double cy = read(1, i) * coordScale;
      final double w = read(2, i) * coordScale;
      final double h = read(3, i) * coordScale;

      raw.add(Detection(
        classId: bestCls,
        label: label,
        confidence: bestScore,
        x1: cx - w / 2,
        y1: cy - h / 2,
        x2: cx + w / 2,
        y2: cy + h / 2,
        distanceMeters: double.nan,
        distanceSource: 'none',
        touchesEdge: false,
      ));
    }

    // ignore: avoid_print
    print('  REJECTIONS: floor=$rejFloor ignore=$rejIgnore '
        'classThresh=$rejClassThresh -> raw=${raw.length}');

    // ============================================================
    // PASS 3: NMS within same class
    // ============================================================
    raw.sort((a, b) => b.confidence.compareTo(a.confidence));
    final afterSameClass = <Detection>[];
    for (final d in raw) {
      bool suppress = false;
      for (final k in afterSameClass) {
        if (d.label == k.label && _iou(d, k) > nmsThreshold) {
          suppress = true; break;
        }
      }
      if (!suppress) afterSameClass.add(d);
    }

    // ============================================================
    // PASS 4: cross-class NMS (Person+Man+Woman dedupe)
    // ============================================================
    final afterCross = <Detection>[];
    for (final d in afterSameClass) {
      bool suppress = false;
      final dCanon = _canonical(d.label);
      for (final k in afterCross) {
        final kCanon = _canonical(k.label);
        if (dCanon == kCanon && _iou(d, k) > crossClassNmsThreshold) {
          suppress = true; break;
        }
      }
      if (!suppress) afterCross.add(d);
    }

    // ============================================================
    // PASS 5: reverse-letterbox + edge/area/aspect filters
    // ============================================================
    int rejTiny = 0, rejArea = 0, rejAspect = 0;
    final kept = <Detection>[];

    for (final d in afterCross) {
      double x1 = (d.x1 - lb.padX) / lb.scale;
      double y1 = (d.y1 - lb.padY) / lb.scale;
      double x2 = (d.x2 - lb.padX) / lb.scale;
      double y2 = (d.y2 - lb.padY) / lb.scale;

      final tolX = originalImage.width * edgeTolerance;
      final tolY = originalImage.height * edgeTolerance;
      final edge = x1 < tolX || y1 < tolY ||
          x2 > originalImage.width - tolX ||
          y2 > originalImage.height - tolY;

      x1 = x1.clamp(0.0, originalImage.width.toDouble());
      y1 = y1.clamp(0.0, originalImage.height.toDouble());
      x2 = x2.clamp(0.0, originalImage.width.toDouble());
      y2 = y2.clamp(0.0, originalImage.height.toDouble());

      if (x2 - x1 < 2 || y2 - y1 < 2) { rejTiny++; continue; }

      final boxArea = (x2 - x1) * (y2 - y1);
      final areaFrac = boxArea / imageArea;
      if (areaFrac < _minAreaFrac(d.label)) { rejArea++; continue; }

      final aspect = (x2 - x1) / (y2 - y1);
      final canon = _canonical(d.label);
      if (canon == 'person' && aspect > 1.5) { rejAspect++; continue; }

      kept.add(Detection(
        classId: d.classId,
        label: d.label,
        confidence: d.confidence,
        x1: x1, y1: y1, x2: x2, y2: y2,
        distanceMeters: double.nan,
        distanceSource: 'none',
        touchesEdge: edge,
      ));
    }

    // ignore: avoid_print
    print('=== YOLO KEPT ${kept.length} === '
        '(rejTiny=$rejTiny rejArea=$rejArea rejAspect=$rejAspect)');
    for (final d in kept) {
      // ignore: avoid_print
      print('   ${d.label} conf=${d.confidence.toStringAsFixed(3)} '
          'edge=${d.touchesEdge} '
          'bbox=(${d.x1.toInt()},${d.y1.toInt()})-'
          '(${d.x2.toInt()},${d.y2.toInt()}) '
          'w=${(d.x2 - d.x1).toInt()} h=${(d.y2 - d.y1).toInt()}');
    }

    return kept;
  }

  double _iou(Detection a, Detection b) {
    final x1 = a.x1 > b.x1 ? a.x1 : b.x1;
    final y1 = a.y1 > b.y1 ? a.y1 : b.y1;
    final x2 = a.x2 < b.x2 ? a.x2 : b.x2;
    final y2 = a.y2 < b.y2 ? a.y2 : b.y2;
    final iw = (x2 - x1).clamp(0.0, double.infinity);
    final ih = (y2 - y1).clamp(0.0, double.infinity);
    final inter = iw * ih;
    final aw = a.x2 - a.x1, ah = a.y2 - a.y1;
    final bw = b.x2 - b.x1, bh = b.y2 - b.y1;
    final union = aw * ah + bw * bh - inter;
    return union <= 0 ? 0 : inter / union;
  }

  void close() => interpreter.close();
}