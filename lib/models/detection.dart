class Detection {
  final int classId;
  final String label;
  final double confidence;
  final double x1, y1, x2, y2;
  final double distanceMeters;
  final String distanceSource;
  final bool touchesEdge;

  const Detection({
    required this.classId,
    required this.label,
    required this.confidence,
    required this.x1, required this.y1,
    required this.x2, required this.y2,
    required this.distanceMeters,
    required this.distanceSource,
    this.touchesEdge = false,
  });

  double get width => x2 - x1;
  double get height => y2 - y1;
  double get cx => (x1 + x2) / 2.0;
  double get cy => (y1 + y2) / 2.0;
}

enum DistanceZone {
  veryClose,
  close,
  medium,
  far,
  veryFar,
  unknown,
}

extension DistanceZoneSpeech on DistanceZone {
  String get speech {
    switch (this) {
      case DistanceZone.veryClose: return 'very close';
      case DistanceZone.close: return 'close';
      case DistanceZone.medium: return 'medium range';
      case DistanceZone.far: return 'far';
      case DistanceZone.veryFar: return 'very far';
      case DistanceZone.unknown: return 'unknown distance';
    }
  }
}

DistanceZone zoneFromMeters(double m, {required bool edgeClipped}) {
  if (edgeClipped) return DistanceZone.veryClose;
  if (!m.isFinite || m <= 0) return DistanceZone.unknown;
  if (m < 1.0) return DistanceZone.veryClose;
  if (m < 2.0) return DistanceZone.close;
  if (m < 4.0) return DistanceZone.medium;
  if (m < 8.0) return DistanceZone.far;
  return DistanceZone.veryFar;
}

enum Direction { left, center, right }

extension DirectionSpeech on Direction {
  String get speech {
    switch (this) {
      case Direction.left: return 'on your left';
      case Direction.center: return 'ahead';
      case Direction.right: return 'on your right';
    }
  }
}

Direction directionFromCenter(double bboxCx, int imageWidth) {
  final f = bboxCx / imageWidth;
  if (f < 0.38) return Direction.left;
  if (f > 0.62) return Direction.right;
  return Direction.center;
}