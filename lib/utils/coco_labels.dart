/// Per-class distance estimation accuracy notes:
///
/// TIGHT priors (±15-20% accurate within 1-5m):
///   * person   (1.70m, low population variance)
///   * laptop   (0.22m closed-screen height)
///   * bottle   (0.25m typical water bottle)
///   * stop sign (0.75m diameter — standardized worldwide)
///   * car       (1.50m height — fairly standardized for sedans/hatchbacks)
///
/// LOOSE priors (errors can exceed 50%):
///   * suitcase   — varies 45cm to 145cm depending on size and handle position
///   * backpack   — varies 30cm to 70cm
///   * book       — varies dramatically by genre
///   * cup        — varies tableware to mug to thermos
///   * bus/truck  — height varies enormously by vehicle type
///
/// LIMITATION: Pinhole + per-class priors fundamentally cannot resolve
/// size variation within a class. Future work: MiDaS scale-shift fusion
/// (see distance_estimator.dart fitScaleShift / fuseDistances) would
/// remove per-class size dependence by anchoring relative depth to
/// reliable-prior objects in the same frame.

const List<String> cocoLabels = <String>[
  'person', 'bicycle', 'car', 'motorcycle', 'airplane', 'bus', 'train', 'truck',
  'boat', 'traffic light', 'fire hydrant', 'stop sign', 'parking meter', 'bench',
  'bird', 'cat', 'dog', 'horse', 'sheep', 'cow', 'elephant', 'bear', 'zebra',
  'giraffe', 'backpack', 'umbrella', 'handbag', 'tie', 'suitcase', 'frisbee',
  'skis', 'snowboard', 'sports ball', 'kite', 'baseball bat', 'baseball glove',
  'skateboard', 'surfboard', 'tennis racket', 'bottle', 'wine glass', 'cup',
  'fork', 'knife', 'spoon', 'bowl', 'banana', 'apple', 'sandwich', 'orange',
  'broccoli', 'carrot', 'hot dog', 'pizza', 'donut', 'cake', 'chair', 'couch',
  'potted plant', 'bed', 'dining table', 'toilet', 'tv', 'laptop', 'mouse',
  'remote', 'keyboard', 'cell phone', 'microwave', 'oven', 'toaster', 'sink',
  'refrigerator', 'book', 'clock', 'vase', 'scissors', 'teddy bear', 'hair drier',
  'toothbrush',
];

/// Classes intentionally suppressed because they are noisy in our test
/// environments or irrelevant for navigation.
///
/// Notes on what is NOT ignored (i.e. things we DO speak about):
///   * Vehicles: bicycle, car, motorcycle, bus, truck — relevant for
///     pedestrian safety and the most reliable outdoor signals.
///   * Street furniture: traffic light, stop sign, fire hydrant,
///     parking meter, bench — useful spatial waypoints outdoors.
///   * Indoor objects: chair, sofa, bed, table, all common appliances,
///     electronics, basic kitchenware.
///   * Cat and dog — common companions, sometimes safety-relevant.
const Set<String> ignoredLabels = <String>{
  // Animals other than cat/dog — too noisy indoors, false positives
  // confuse the user. Re-enable per-class if your demo is at a zoo.
  'bird','horse','sheep','cow','elephant','bear','zebra','giraffe',

  // Vehicles unlikely to appear in everyday navigation. Cars, buses,
  // motorbikes, bicycles and trucks remain enabled.
  'airplane','boat','train',

  // Sports gear — rare in real navigation, frequent false positives.
  'frisbee','skis','snowboard','kite','baseball bat','baseball glove',
  'skateboard','surfboard','tennis racket','sports ball',

  // Food — frequent false positives in cluttered indoor scenes,
  // and not safety-relevant.
  'banana','apple','orange','broccoli','carrot','sandwich','pizza',
  'donut','cake','hot dog',

  // Small cutlery — tiny in frame, false-fires constantly.
  'fork','knife','spoon','scissors',

  // Personal items — demo noise.
  'tie','hair drier','toothbrush',
};

const double defaultConfThreshold = 0.35;
const Map<String, double> perClassConfThreshold = <String, double>{
  // High-precision categories (we don't want false alarms).
  'person': 0.55,
  'dog': 0.60,
  'cat': 0.55,
  'teddy bear': 0.50,
  'potted plant': 0.45,
  'vase': 0.45,
  'book': 0.45,
  'cell phone': 0.45,
  'remote': 0.50,
  'mouse': 0.50,
  'clock': 0.45,

  // Re-enabled outdoor classes. Conservative thresholds because false
  // positives on these classes can be safety-relevant (a hallucinated
  // stop sign matters). Empirically COCO YOLO is reliable on these
  // above ~0.45 confidence.
  'traffic light': 0.45,
  'stop sign': 0.50,
  'fire hydrant': 0.45,
  'parking meter': 0.45,
  'bench': 0.45,

  // ============================================================
  // VEHICLES — LOWERED THRESHOLDS for safety-critical detection.
  //
  // Rationale: A missed car is a safety risk for a blind user; a
  // false-positive car is a minor annoyance. We deliberately bias
  // toward over-detection. Empirically YOLO11n on COCO produces
  // car confidences in the 0.30-0.55 range at typical pedestrian
  // viewing angles (3/4 view, side view, partially occluded).
  //
  // The previous default of 0.35 was rejecting borderline cars.
  // Bus/truck thresholds are also lowered because YOLO often
  // confuses them with each other at distance — we'd rather
  // announce "vehicle" reliably than miss it.
  // ============================================================
  'car': 0.30,
  'bus': 0.30,
  'truck': 0.30,
  'motorcycle': 0.35,
  'bicycle': 0.30,
};

const double defaultMinAreaFrac = 0.003;
const Map<String, double> perClassMinAreaFrac = <String, double>{
  'person': 0.02,
  'chair': 0.015,
  'couch': 0.04,
  'bed': 0.05,
  'refrigerator': 0.04,
  'dining table': 0.04,
  'oven': 0.015,
  'microwave': 0.01,
  'tv': 0.015,
  'laptop': 0.01,
  'toilet': 0.01,
  'suitcase': 0.01,
  'bottle': 0.001,
  'cup': 0.001,
  'cell phone': 0.002,

  // Re-enabled outdoor classes. Min area is generous (small) because
  // a stop sign 30m away is still a relevant signal even if it's only
  // a few percent of the frame. Setting these too high silently
  // suppresses the very-far announcements we care about for navigation.
  'traffic light': 0.0015,
  'stop sign': 0.002,
  'fire hydrant': 0.002,
  'parking meter': 0.002,
  'bench': 0.005,

  // Vehicles — area thresholds tuned for pedestrian-relevant distances.
  // A car ~10m away occupies roughly 1-2% of frame at 720x1280; we
  // accept down to 1% so cars at the edge of speech-relevant range
  // (~15-20m) still announce. Smaller than that and the box is too
  // unreliable for distance estimation anyway.
  'car': 0.01,
  'bus': 0.015,
  'truck': 0.012,
  'motorcycle': 0.005,
  'bicycle': 0.003,
};

class ObjectPrior {
  final double dim;
  final String axis;
  final bool reliable;
  const ObjectPrior(this.dim, this.axis, this.reliable);
}

final Map<String, ObjectPrior> cocoObjectPriors = <String, ObjectPrior>{
  'person': const ObjectPrior(1.70, 'h', true),
  'chair': const ObjectPrior(0.90, 'h', true),
  'couch': const ObjectPrior(0.85, 'h', false),
  'bed': const ObjectPrior(0.60, 'h', false),
  'dining table': const ObjectPrior(0.75, 'h', false),
  'toilet': const ObjectPrior(0.40, 'h', true),
  'tv': const ObjectPrior(0.65, 'h', true),
  'laptop': const ObjectPrior(0.22, 'h', true),
  'mouse': const ObjectPrior(0.06, 'h', false),
  'remote': const ObjectPrior(0.18, 'h', false),
  'keyboard': const ObjectPrior(0.15, 'h', false),
  'cell phone': const ObjectPrior(0.16, 'h', false),
  'microwave': const ObjectPrior(0.30, 'h', true),
  'oven': const ObjectPrior(0.85, 'h', true),
  'sink': const ObjectPrior(0.20, 'h', false),
  'refrigerator': const ObjectPrior(1.70, 'h', true),
  'book': const ObjectPrior(0.22, 'h', false),
  'clock': const ObjectPrior(0.28, 'h', false),
  'vase': const ObjectPrior(0.25, 'h', false),
  'suitcase': const ObjectPrior(0.55, 'h', true),
  'backpack': const ObjectPrior(0.45, 'h', false),
  'handbag': const ObjectPrior(0.28, 'h', false),
  'umbrella': const ObjectPrior(0.85, 'h', false),
  'bottle': const ObjectPrior(0.25, 'h', true),
  'wine glass': const ObjectPrior(0.22, 'h', false),
  'cup': const ObjectPrior(0.10, 'h', false),
  'bowl': const ObjectPrior(0.08, 'h', false),
  'cat': const ObjectPrior(0.25, 'h', false),
  'dog': const ObjectPrior(0.50, 'h', false),
  'potted plant': const ObjectPrior(0.40, 'h', false),
  'bench': const ObjectPrior(0.50, 'h', true), // typical seat height
  'teddy bear': const ObjectPrior(0.35, 'h', false),
  'toaster': const ObjectPrior(0.20, 'h', false),

  // Re-enabled outdoor priors. Stop signs, hydrants, and parking
  // meters are pleasingly standardized, so distance estimation here
  // is more reliable than for indoor variable-size objects.
  'stop sign': const ObjectPrior(0.75, 'h', true),       // standard octagon ~75cm
  'traffic light': const ObjectPrior(1.00, 'h', false),  // varies; 3-light ≈ 1m
  'fire hydrant': const ObjectPrior(0.70, 'h', true),    // pretty standard
  'parking meter': const ObjectPrior(1.50, 'h', false),  // post height varies

  // Vehicles — useful when YOLO returns one (segmentation also flags
  // these but YOLO gives precise bbox for distance).
  'car': const ObjectPrior(1.50, 'h', true),
  'bus': const ObjectPrior(3.00, 'h', false),
  'truck': const ObjectPrior(2.50, 'h', false),
  'motorcycle': const ObjectPrior(1.20, 'h', false),
  'bicycle': const ObjectPrior(1.10, 'h', false),
};

String prettyLabel(String coco) {
  switch (coco) {
    case 'tv': return 'television';
    case 'cell phone': return 'phone';
    case 'potted plant': return 'plant';
    case 'dining table': return 'table';
    case 'couch': return 'sofa';
    default: return coco;
  }
}