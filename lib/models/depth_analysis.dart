/// Models for MiDaS-style monocular depth analysis.
///
/// MiDaS outputs *relative* depth — bigger value = closer to camera. The raw
/// numbers are not metres and not comparable across frames, so we always
/// normalise per-frame using the global min/max before deciding which
/// region is dangerous.
enum ObstacleZone {
  /// No obstacle detected in this region.
  clear,

  /// Obstacle is far away — no immediate concern.
  far,

  /// Obstacle within a few metres — the user should be aware.
  near,

  /// Obstacle right in front — risk of bumping into it within one or two steps.
  veryClose,
}

extension ObstacleZoneSpeech on ObstacleZone {
  String get phrase {
    switch (this) {
      case ObstacleZone.clear:
        return 'clear';
      case ObstacleZone.far:
        return 'something in the distance';
      case ObstacleZone.near:
        return 'obstacle nearby';
      case ObstacleZone.veryClose:
        return 'obstacle very close';
    }
  }
}

class DepthRegionAnalysis {
  /// 'left' | 'center' | 'right'
  final String regionName;

  /// Closest pixel in this region, raw MiDaS units.
  final double closestRelativeDepth;

  /// Average depth across the region, raw MiDaS units.
  final double avgRelativeDepth;

  /// Closest pixel normalised to [0, 1] vs this frame's global range.
  final double normalizedClosest;

  final ObstacleZone zone;

  const DepthRegionAnalysis({
    required this.regionName,
    required this.closestRelativeDepth,
    required this.avgRelativeDepth,
    required this.normalizedClosest,
    required this.zone,
  });
}

class DepthAnalysis {
  final DepthRegionAnalysis left;
  final DepthRegionAnalysis center;
  final DepthRegionAnalysis right;

  /// Frame-wide min / max of raw MiDaS values, useful for debugging.
  final double globalMin;
  final double globalMax;

  const DepthAnalysis({
    required this.left,
    required this.center,
    required this.right,
    required this.globalMin,
    required this.globalMax,
  });

  /// True if any region has zone >= near (anything we should mention).
  bool get hasRelevantObstacle =>
      left.zone.index >= ObstacleZone.near.index ||
      center.zone.index >= ObstacleZone.near.index ||
      right.zone.index >= ObstacleZone.near.index;

  /// True if any region is veryClose — caller may want to elevate urgency.
  bool get hasUrgentObstacle =>
      left.zone == ObstacleZone.veryClose ||
      center.zone == ObstacleZone.veryClose ||
      right.zone == ObstacleZone.veryClose;
}
