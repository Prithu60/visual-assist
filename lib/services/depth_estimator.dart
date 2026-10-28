import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../models/depth_analysis.dart';

/// Wraps a MiDaS TFLite model. Tested target: midas_v2_1_small_int8_256.tflite.
///
/// Honest caveats:
///   * MiDaS gives RELATIVE depth, not metres.
///   * Per-frame min/max normalisation means the closest pixel is
///     ALWAYS 1.0, so we use a CONTEXTUAL gap metric (this region's
///     closeness vs the typical bottom-half pixel) instead of an
///     absolute threshold.
///   * Only the bottom 60% of the frame is used — the top is
///     sky/ceiling and dragging it into "closest pixel" makes the
///     result unstable.
///
/// What changed from the previous version (the "veryClose on
/// everything" fix):
///   * Reference is now the bottom-half MEDIAN of all raw values
///     (frame-wide, stable) instead of the median of the three
///     per-region averages (which itself is a region statistic and
///     amplifies bias).
///   * Region "closeness" is now the 95th-percentile depth value
///     instead of the absolute max. A single hot pixel can no longer
///     trigger a STOP — a substantial portion of the region must be
///     close.
///   * Thresholds raised to be more conservative. "veryClose" now
///     requires the region to be very dramatically closer than typical.
///
/// What's NEW (Phase 5 — MiDaS scale-shift fusion support):
///   * After analyze() runs, the raw MiDaS output is cached in
///     [lastRawMap], with dimensions [lastMapWidth] × [lastMapHeight].
///   * IsolateInference reads these to sample median MiDaS values
///     inside YOLO bounding boxes, then calls fuseDistances() in
///     distance_estimator.dart to correct loose-prior class distances
///     (suitcase, bus, truck, etc.) using reliable-prior anchors.
///   * The cache is INVALIDATED on every analyze() call — only the
///     most recent frame's depth map is held. Don't read these fields
///     between frames.
class DepthEstimator {
  static const int inputSize = 256;

  Interpreter? _interpreter;
  bool _outputIs4D = false; // detected on first run

  bool get isLoaded => _interpreter != null;

  // ---------------------------------------------------------------------------
  // Phase 5 cache: most-recent raw depth map for downstream MiDaS fusion.
  //
  // These fields are populated by analyze() and read by
  // IsolateInference._sampleMidasMedians(). Higher raw values =
  // closer (MiDaS outputs inverse depth / disparity).
  //
  // The map is stored as a flat row-major List<double> of length
  // (lastMapWidth * lastMapHeight) — flat because it's cheaper to
  // index from the sampling code than a nested list, and we're
  // building it from a flat source anyway.
  // ---------------------------------------------------------------------------

  /// Raw MiDaS output from the most recent analyze() call, flattened
  /// row-major. Length is [lastMapWidth] * [lastMapHeight].
  /// Null until the first successful analyze().
  List<double>? lastRawMap;

  /// Width of the MiDaS output grid for the most recent frame.
  /// Equals [inputSize] (256) for the small INT8 model.
  int? lastMapWidth;

  /// Height of the MiDaS output grid for the most recent frame.
  int? lastMapHeight;

  Future<void> load(String assetPath) async {
    final options = InterpreterOptions()..threads = 2;
    _interpreter = await Interpreter.fromAsset(assetPath, options: options);

    final outShape = _interpreter!.getOutputTensor(0).shape;
    // Could be [1, 256, 256] or [1, 256, 256, 1] depending on the export.
    _outputIs4D = outShape.length == 4;
  }

  /// Reopen an interpreter from a memory address that was created on
  /// another isolate. This is used by IsolateInference.
  void loadFromAddress(int address) {
    _interpreter = Interpreter.fromAddress(address);

    final outShape = _interpreter!.getOutputTensor(0).shape;
    _outputIs4D = outShape.length == 4;
  }

  void close() {
    _interpreter?.close();
    _interpreter = null;
    lastRawMap = null;
    lastMapWidth = null;
    lastMapHeight = null;
  }

  DepthAnalysis? analyze(img.Image source) {
    final interpreter = _interpreter;
    if (interpreter == null) return null;

    final resized = img.copyResize(
      source,
      width: inputSize,
      height: inputSize,
      interpolation: img.Interpolation.linear,
    );

    // ImageNet-style normalisation expected by MiDaS
    final input = List.generate(
      1,
      (_) => List.generate(
        inputSize,
        (y) => List.generate(
          inputSize,
          (x) {
            final p = resized.getPixel(x, y);
            return [
              ((p.r / 255.0) - 0.485) / 0.229,
              ((p.g / 255.0) - 0.456) / 0.224,
              ((p.b / 255.0) - 0.406) / 0.225,
            ];
          },
        ),
      ),
    );

    // Allocate the right output shape on first run.
    final List<List<double>> depthMap;
    if (_outputIs4D) {
      final out = List.generate(
        1,
        (_) => List.generate(
          inputSize,
          (_) => List.generate(inputSize, (_) => List<double>.filled(1, 0.0)),
        ),
      );
      interpreter.run(input, out);
      depthMap = List.generate(
        inputSize,
        (y) => List.generate(inputSize, (x) => out[0][y][x][0]),
      );
    } else {
      final out = List.generate(
        1,
        (_) =>
            List.generate(inputSize, (_) => List<double>.filled(inputSize, 0.0)),
      );
      interpreter.run(input, out);
      depthMap = out[0];
    }

    // ----------------------------------------------------------------
    // Phase 5: cache the raw map for downstream MiDaS scale-shift
    // fusion (read by IsolateInference._sampleMidasMedians).
    //
    // We flatten row-major. Cost is one allocation of size 256*256 =
    // 65,536 doubles per frame, which is trivial compared to the
    // ~700ms MiDaS inference itself.
    // ----------------------------------------------------------------
    final flat = List<double>.filled(inputSize * inputSize, 0.0);
    for (int y = 0; y < inputSize; y++) {
      for (int x = 0; x < inputSize; x++) {
        flat[y * inputSize + x] = depthMap[y][x];
      }
    }
    lastRawMap = flat;
    lastMapWidth = inputSize;
    lastMapHeight = inputSize;

    return _buildAnalysis(depthMap);
  }

  // ---------------------------------------------------------------------------
  // Analysis
  // ---------------------------------------------------------------------------

  DepthAnalysis _buildAnalysis(List<List<double>> depthMap) {
    // Frame-wide normalisation range.
    var globalMin = double.infinity;
    var globalMax = double.negativeInfinity;
    for (var y = 0; y < inputSize; y++) {
      for (var x = 0; x < inputSize; x++) {
        final v = depthMap[y][x];
        if (v < globalMin) globalMin = v;
        if (v > globalMax) globalMax = v;
      }
    }
    final range = (globalMax - globalMin).abs();

    // Walk-relevant region: bottom 60% of frame.
    final yStart = (inputSize * 0.4).round();
    final third = inputSize ~/ 3;

    // ---------------------------------------------------------------
    // Frame-wide reference: bottom-half MEDIAN raw value, normalized.
    // This is more stable than "the average of three region averages"
    // because it doesn't get pulled by any single region's bias.
    // ---------------------------------------------------------------
    final bottomVals = <double>[];
    for (var y = yStart; y < inputSize; y++) {
      for (var x = 0; x < inputSize; x++) {
        bottomVals.add(depthMap[y][x]);
      }
    }
    bottomVals.sort();
    final double refRaw = _percentile(bottomVals, 0.50);
    final double refNormalized =
        range > 1e-6 ? (refRaw - globalMin) / range : 0.0;

    // Pass 1: per-region "robust closeness" via 95th percentile.
    DepthRegionAnalysis rawRegion(int xStart, int xEnd, String name) {
      final regionVals = <double>[];
      var rawMax = double.negativeInfinity;
      var sum = 0.0;
      var count = 0;

      for (var y = yStart; y < inputSize; y++) {
        for (var x = xStart; x < xEnd; x++) {
          final v = depthMap[y][x];
          regionVals.add(v);
          if (v > rawMax) rawMax = v;
          sum += v;
          count++;
        }
      }

      regionVals.sort();
      // Robust closest = 95th percentile. Tolerates a few hot pixels
      // without firing alarms; requires a real, sustained close edge.
      final double robustClosest = _percentile(regionVals, 0.95);

      final avg = count > 0 ? sum / count : 0.0;
      // We expose "normalizedClosest" as the normalized robust closest.
      // The DepthRegionAnalysis model field name doesn't change so the
      // rest of the app keeps working.
      final norm = range > 1e-6 ? (robustClosest - globalMin) / range : 0.0;

      return DepthRegionAnalysis(
        regionName: name,
        // Keep raw max for diagnostic / overlay use; it's still
        // semantically "closest single pixel observed."
        closestRelativeDepth: rawMax,
        avgRelativeDepth: avg,
        // Normalized robust (p95) closeness drives zone classification.
        normalizedClosest: norm,
        zone: ObstacleZone.clear,
      );
    }

    final leftRaw = rawRegion(0, third, 'left');
    final centerRaw = rawRegion(third, third * 2, 'center');
    final rightRaw = rawRegion(third * 2, inputSize, 'right');

    // Pass 2: assign zones from gap = robustClosest_norm − refNorm.
    DepthRegionAnalysis withZone(DepthRegionAnalysis r) {
      final gap = r.normalizedClosest - refNormalized;
      return DepthRegionAnalysis(
        regionName: r.regionName,
        closestRelativeDepth: r.closestRelativeDepth,
        avgRelativeDepth: r.avgRelativeDepth,
        normalizedClosest: r.normalizedClosest,
        zone: _zoneForGap(gap),
      );
    }

    return DepthAnalysis(
      left: withZone(leftRaw),
      center: withZone(centerRaw),
      right: withZone(rightRaw),
      globalMin: globalMin,
      globalMax: globalMax,
    );
  }

  /// Linear-interpolation percentile over a SORTED list.
  /// Returns 0 for an empty list.
  static double _percentile(List<double> sorted, double p) {
    if (sorted.isEmpty) return 0.0;
    if (p <= 0) return sorted.first;
    if (p >= 1) return sorted.last;
    final idx = (sorted.length - 1) * p;
    final lo = idx.floor();
    final hi = idx.ceil();
    if (lo == hi) return sorted[lo];
    final frac = idx - lo;
    return sorted[lo] * (1 - frac) + sorted[hi] * frac;
  }

  /// Map a region's closeness GAP (vs the bottom-half median pixel)
  /// to a spoken zone.
  ///
  /// Why this is contextual: MiDaS's normalised output always has at
  /// least one pixel at 1.0 by definition. Treating 1.0 as "physically
  /// very close" produces "STOP" on every frame. Instead we ask: "is
  /// the bulk of this region (its 95th percentile) MEANINGFULLY closer
  /// than the typical bottom-half pixel of this frame?"
  ///
  /// Thresholds (raised from the previous version, which fired
  /// veryClose on basically every indoor frame):
  ///
  ///   gap > 0.45 → veryClose  (region is dramatically closer than
  ///                            typical — real obstacle, worth a STOP)
  ///   gap > 0.28 → near       (clearly closer; worth a soft warning)
  ///   gap > 0.15 → far        (mild closeness; informational only)
  ///   otherwise  → clear
  ///
  /// Caveats unchanged from before:
  ///   * In a totally flat scene (e.g. a wall filling the frame at
  ///     1 m), all gaps are small and we report 'clear'. Correct from
  ///     a navigation standpoint — there's nothing differentially
  ///     worth steering around — even though something IS physically
  ///     there. YOLO + segmentation are the safety nets for that case.
  ///   * For real "I'm about to walk into a wall" detection you'd
  ///     want metric depth, not relative MiDaS.
  ObstacleZone _zoneForGap(double regionGap) {
    if (regionGap > 0.45) return ObstacleZone.veryClose;
    if (regionGap > 0.28) return ObstacleZone.near;
    if (regionGap > 0.15) return ObstacleZone.far;
    return ObstacleZone.clear;
  }
}