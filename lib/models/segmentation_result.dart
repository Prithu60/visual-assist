/// Pascal VOC 21-class label set used by the Google mobile DeepLabV3 export
/// (deeplabv3_257_mv_gpu.tflite).
///
/// Pascal VOC is NOT ideal for blind-navigation use because it has no
/// "sidewalk", "road", "floor", or "terrain" class — anything that isn't
/// one of the 20 named objects below is just "background". A proper
/// Cityscapes mobile model would be better for path detection; we use
/// this one because it's the canonical mobile-friendly DeepLab export
/// from Google and it loads reliably with tflite_flutter 0.11.
///
/// The HONEST consequence: we no longer claim "path is clear" from
/// segmentation alone, because a wall and a hallway are both
/// "background" to PASCAL VOC. We only speak the SIGNALS WE TRUST —
/// vehicle and person presence — and let depth + YOLO carry the rest.
enum PascalVocClass {
  background,
  aeroplane,
  bicycle,
  bird,
  boat,
  bottle,
  bus,
  car,
  cat,
  chair,
  cow,
  diningtable,
  dog,
  horse,
  motorbike,
  person,
  pottedplant,
  sheep,
  sofa,
  train,
  tvmonitor,
  unknown,
}

PascalVocClass pascalVocClassFromIndex(int idx) {
  switch (idx) {
    case 0:
      return PascalVocClass.background;
    case 1:
      return PascalVocClass.aeroplane;
    case 2:
      return PascalVocClass.bicycle;
    case 3:
      return PascalVocClass.bird;
    case 4:
      return PascalVocClass.boat;
    case 5:
      return PascalVocClass.bottle;
    case 6:
      return PascalVocClass.bus;
    case 7:
      return PascalVocClass.car;
    case 8:
      return PascalVocClass.cat;
    case 9:
      return PascalVocClass.chair;
    case 10:
      return PascalVocClass.cow;
    case 11:
      return PascalVocClass.diningtable;
    case 12:
      return PascalVocClass.dog;
    case 13:
      return PascalVocClass.horse;
    case 14:
      return PascalVocClass.motorbike;
    case 15:
      return PascalVocClass.person;
    case 16:
      return PascalVocClass.pottedplant;
    case 17:
      return PascalVocClass.sheep;
    case 18:
      return PascalVocClass.sofa;
    case 19:
      return PascalVocClass.train;
    case 20:
      return PascalVocClass.tvmonitor;
    default:
      return PascalVocClass.unknown;
  }
}

enum NavigationDirection { left, center, right, stop }

/// Per-frame path analysis. Honest mode under PASCAL VOC:
///
///   * recommendedDirection — always [NavigationDirection.stop]. We
///     do NOT claim a walking direction from "background" pixels,
///     because background covers walls, sky, and obstacles VOC has no
///     class for. Use depth + YOLO for that.
///   * sidewalkVisible — always false (VOC has no sidewalk class).
///   * roadVisible — always false (VOC has no road class).
///   * vehicleVisible — true if any car/bus/motorbike/bicycle/train
///     pixel was found in the bottom region. Reliable.
///   * personVisible — true if any person pixel was found in the
///     bottom region. Reliable.
///   * personLeft / personCenter / personRight — directional flags so
///     the spoken cue can say "Person on your left" rather than just
///     "Person somewhere ahead."
///   * *Walkable — fraction of "background" pixels in that third.
///     KEPT for the result list / overlay UI but NO LONGER consulted
///     for the recommended direction. Treat as a soft hint only.
///   * *Road — repurposed under VOC: fraction of pixels containing a
///     known obstacle (vehicle or person). Higher = more dangerous
///     third.
class PathAnalysis {
  /// Where the user should head if they want to keep walking.
  /// Honest mode: always [NavigationDirection.stop]. PASCAL VOC cannot
  /// reliably identify a walkable surface, so we don't claim one.
  final NavigationDirection recommendedDirection;

  /// (Pascal VOC backend: always false — no sidewalk class.)
  final bool sidewalkVisible;

  /// (Pascal VOC backend: always false — no road class.)
  final bool roadVisible;

  /// True if any vehicle (car/bus/motorbike/bicycle/train) pixel was
  /// found in the bottom region of the frame.
  final bool vehicleVisible;

  /// True if any person pixel was found in the bottom region.
  final bool personVisible;

  /// True if a person was found in this third of the bottom region.
  final bool personLeft;
  final bool personCenter;
  final bool personRight;

  /// Fraction of pixels in this third that look unobstructed
  /// ("background" in Pascal VOC). KEPT for diagnostics — do NOT use
  /// to decide path direction.
  final double leftWalkable;
  final double centerWalkable;
  final double rightWalkable;

  /// Fraction of pixels in this third occupied by a known obstacle
  /// (vehicle or person). High values are a hazard signal.
  final double leftRoad;
  final double centerRoad;
  final double rightRoad;

  const PathAnalysis({
    required this.recommendedDirection,
    required this.sidewalkVisible,
    required this.roadVisible,
    required this.vehicleVisible,
    required this.personVisible,
    required this.personLeft,
    required this.personCenter,
    required this.personRight,
    required this.leftWalkable,
    required this.centerWalkable,
    required this.rightWalkable,
    required this.leftRoad,
    required this.centerRoad,
    required this.rightRoad,
  });
}