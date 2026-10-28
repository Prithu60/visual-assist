import '../models/detection.dart';
import '../utils/coco_labels.dart';
import 'camera_intrinsics.dart';

/// Scale-shift parameters for MiDaS alignment:
///   1/Z_metric ~= s * midas_raw + t
class ScaleShift {
  final double s;
  final double t;
  const ScaleShift(this.s, this.t);
}

/// Pinhole distance estimate. Returns NaN if no prior is known for the class.
///
/// For axis='h':  Z = (H_real * fy_px) / bbox_height_px
/// For axis='w':  Z = (W_real * fx_px) / bbox_width_px
double pinholeDistance(Detection d, CameraIntrinsics cam) {
  final prior = cocoObjectPriors[d.label];
  if (prior == null) return double.nan;
  if (prior.axis == 'h') {
    if (d.height <= 0) return double.nan;
    return prior.dim * cam.fyPixels / d.height;
  } else {
    if (d.width <= 0) return double.nan;
    return prior.dim * cam.fxPixels / d.width;
  }
}

/// Solve least-squares  1/Z_i  =  s * midas_i + t  over N anchors.
/// Closed-form 2x2 normal equations.
ScaleShift fitScaleShift(List<double> pinholeDist, List<double> midasRaw) {
  assert(pinholeDist.length == midasRaw.length && pinholeDist.length >= 2);
  final n = pinholeDist.length;
  double sx = 0, sy = 0, sxx = 0, sxy = 0;
  for (int i = 0; i < n; i++) {
    final double x = midasRaw[i];
    final double y = 1.0 / pinholeDist[i];
    sx += x;
    sy += y;
    sxx += x * x;
    sxy += x * y;
  }
  final det = n * sxx - sx * sx;
  if (det.abs() < 1e-9) return const ScaleShift(1.0, 0.0);
  return ScaleShift(
    (n * sxy - sx * sy) / det,
    (sxx * sy - sx * sxy) / det,
  );
}

/// Apply the scale-shift transform to a raw MiDaS value -> metric metres.
double midasToMetric(double midasRaw, ScaleShift ss) {
  final disp = ss.s * midasRaw + ss.t;
  if (disp <= 1e-6) return double.infinity;
  return 1.0 / disp;
}

/// Output of the hybrid distance fusion step.
class HybridResult {
  final List<Detection> detections;
  final ScaleShift? ss;
  const HybridResult(this.detections, this.ss);
}

/// Fuse pinhole and MiDaS-aligned distances per detection.
/// - Uses reliable pinhole priors as anchors to solve (s, t).
/// - If there are 2+ anchors, apply the fit to every detection.
/// - Otherwise fall back to pinhole-only where available.
HybridResult fuseDistances(
  List<Detection> raw,
  List<double> midasMedians,
  CameraIntrinsics cam,
) {
  final anchorPin = <double>[];
  final anchorMid = <double>[];

  for (int i = 0; i < raw.length; i++) {
    final p = pinholeDistance(raw[i], cam);
    final prior = cocoObjectPriors[raw[i].label];
    if (p.isFinite &&
        p > 0.2 &&
        p < 30.0 &&
        prior != null &&
        prior.reliable &&
        raw[i].confidence > 0.55 &&
        !midasMedians[i].isNaN) {
      anchorPin.add(p);
      anchorMid.add(midasMedians[i]);
    }
  }

  ScaleShift? ss;
  if (anchorPin.length >= 2) {
    ss = fitScaleShift(anchorPin, anchorMid);
  }

  final out = <Detection>[];
  for (int i = 0; i < raw.length; i++) {
    final pin = pinholeDistance(raw[i], cam);
    double? mid;
    if (ss != null && !midasMedians[i].isNaN) {
      mid = midasToMetric(midasMedians[i], ss);
    }

    double z;
    String src;
    if (pin.isFinite && mid != null && mid.isFinite) {
      z = 0.5 * (pin + mid);
      src = 'hybrid';
    } else if (pin.isFinite) {
      z = pin;
      src = 'pinhole';
    } else if (mid != null && mid.isFinite) {
      z = mid;
      src = 'midas';
    } else {
      z = double.nan;
      src = 'none';
    }

    out.add(Detection(
      classId: raw[i].classId,
      label: raw[i].label,
      confidence: raw[i].confidence,
      x1: raw[i].x1,
      y1: raw[i].y1,
      x2: raw[i].x2,
      y2: raw[i].y2,
      distanceMeters: z,
      distanceSource: src,
    ));
  }

  return HybridResult(out, ss);
}
