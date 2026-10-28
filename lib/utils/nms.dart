import '../models/detection.dart';

double _iou(Detection a, Detection b) {
  final x1 = a.x1 > b.x1 ? a.x1 : b.x1;
  final y1 = a.y1 > b.y1 ? a.y1 : b.y1;
  final x2 = a.x2 < b.x2 ? a.x2 : b.x2;
  final y2 = a.y2 < b.y2 ? a.y2 : b.y2;
  final iw = (x2 - x1).clamp(0.0, double.infinity);
  final ih = (y2 - y1).clamp(0.0, double.infinity);
  final inter = iw * ih;
  final union = a.width * a.height + b.width * b.height - inter;
  return union <= 0 ? 0 : inter / union;
}

/// Class-agnostic Non-Max Suppression.
/// Sorts detections by confidence, greedily keeps boxes whose IoU
/// against every already-kept box is below [iouThreshold].
List<Detection> classAgnosticNms(
  List<Detection> dets, {
  double iouThreshold = 0.45,
}) {
  dets.sort((a, b) => b.confidence.compareTo(a.confidence));
  final keep = <Detection>[];
  for (final d in dets) {
    bool suppressed = false;
    for (final k in keep) {
      if (_iou(d, k) > iouThreshold) {
        suppressed = true;
        break;
      }
    }
    if (!suppressed) keep.add(d);
  }
  return keep;
}
