import 'dart:math' as math;

/// Pinhole camera intrinsics in pixel units, applicable to a captured
/// image of dimensions [imageWidth] × [imageHeight].
///
/// We don't currently solve calibration on-device; instead we estimate
/// `fx` / `fy` from an assumed horizontal field of view. For typical
/// Android phone main cameras (including the AC2001 / OnePlus Nord N10
/// family) the empirical hFOV on Flutter's `ResolutionPreset.high`
/// center-cropped 720×1280 stream is in the 65–75° range. We default
/// to 70°, which gives pinhole distance estimates accurate to roughly
/// ±15–20% on objects in the 1–5 m range with known COCO priors.
///
/// If you have a per-device calibration you trust, plug a different
/// `horizontalFovDegrees` value into [CameraIntrinsicsService.fetch].
class CameraIntrinsics {
  /// Focal length in horizontal-axis pixels.
  final double fxPixels;

  /// Focal length in vertical-axis pixels.
  /// For square pixels and an axis-aligned sensor this equals [fxPixels].
  final double fyPixels;

  /// Principal point (optical center) — usually within ~5% of the
  /// geometric image center on phone cameras. We assume image center.
  final double cxPixels;
  final double cyPixels;

  /// The image dimensions these intrinsics apply to.
  final int imageWidth;
  final int imageHeight;

  /// The horizontal FOV in degrees this was derived from. Stored only
  /// for diagnostics; nothing in the math depends on it after the fact.
  final double horizontalFovDegrees;

  const CameraIntrinsics({
    required this.fxPixels,
    required this.fyPixels,
    required this.cxPixels,
    required this.cyPixels,
    required this.imageWidth,
    required this.imageHeight,
    required this.horizontalFovDegrees,
  });

  /// Build intrinsics from an assumed horizontal field of view.
  ///
  /// Math: for a pinhole camera with horizontal FOV `θ`,
  ///   fx_px = (W / 2) / tan(θ / 2)
  /// We assume square pixels so fy = fx. The vertical FOV is then
  /// implicit in the aspect ratio.
  factory CameraIntrinsics.fromHorizontalFov({
    required int imageWidth,
    required int imageHeight,
    required double horizontalFovDegrees,
  }) {
    final hFovRad = horizontalFovDegrees * math.pi / 180.0;
    final fx = (imageWidth / 2.0) / math.tan(hFovRad / 2.0);
    final fy = fx; // square-pixel assumption
    return CameraIntrinsics(
      fxPixels: fx,
      fyPixels: fy,
      cxPixels: imageWidth / 2.0,
      cyPixels: imageHeight / 2.0,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      horizontalFovDegrees: horizontalFovDegrees,
    );
  }

  @override
  String toString() =>
      'CameraIntrinsics(fx=${fxPixels.toStringAsFixed(1)}, '
      'fy=${fyPixels.toStringAsFixed(1)}, '
      'image=${imageWidth}x$imageHeight, '
      'hFOV=${horizontalFovDegrees.toStringAsFixed(1)}°)';
}

/// Resolves [CameraIntrinsics] for the current device + capture resolution.
///
/// **Today** this just builds intrinsics from a default FOV. There is no
/// platform-channel call yet that queries Camera2 `CameraCharacteristics`
/// (`LENS_INFO_AVAILABLE_FOCAL_LENGTHS` + `SENSOR_INFO_PHYSICAL_SIZE`). If
/// you find the default 70° produces consistently wrong distances on the
/// AC2001, override `horizontalFovDegrees` until pinhole anchors land on
/// known truth (e.g. a person 2 m away should report ~1.7–2.3 m).
///
/// **Tomorrow** (Phase 2 / 3 follow-up) we can replace the body with a
/// `MethodChannel` lookup on Android. The signature of [fetch] is stable so
/// callers won't change.
class CameraIntrinsicsService {
  /// Default horizontal FOV in degrees. Empirically 65–75° covers most
  /// modern phone main cameras at the resolutions we're using.
  static const double defaultHorizontalFovDegrees = 70.0;

  /// Resolve intrinsics for the given image dimensions.
  ///
  /// [imageWidth] / [imageHeight] are the dimensions of the JPEG you'll
  /// actually feed into the detector — usually `previewSize.height` and
  /// `previewSize.width` because Flutter reports preview size in
  /// portrait-rotated coordinates.
  static Future<CameraIntrinsics> fetch({
    required int imageWidth,
    required int imageHeight,
    double horizontalFovDegrees = defaultHorizontalFovDegrees,
  }) async {
    // The async signature is preserved for future platform-channel work.
    return CameraIntrinsics.fromHorizontalFov(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      horizontalFovDegrees: horizontalFovDegrees,
    );
  }
}
