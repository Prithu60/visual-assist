import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../models/segmentation_result.dart';

/// Wraps the Google mobile DeepLabV3 Pascal VOC int8 TFLite model.
///
/// HONEST MODE (this version):
///   * We do NOT report a "walkable direction" from VOC. Pascal VOC
///     has no road, sidewalk, floor, or wall class — so "background"
///     pixels could just as easily be a wall as a hallway. Telling a
///     blind user to walk toward "background" is unsafe.
///   * What we DO trust from VOC: people and vehicles. Both are
///     well-trained classes with reliable masks. We surface those as
///     hazard cues only.
///   * The walkable fractions are still computed and exposed for the
///     debug overlay / result list, but the consumer should treat
///     them as diagnostic, not as a navigation signal.
///
/// Different DeepLab exports use different output tensor shapes
/// ([1,257,257] argmax int vs [1,257,257,21] logits float). We detect
/// and handle both; the Google file is the 4D-logits variant.
class SegmentationService {
  /// 257×257 input — matches the Google mobile DeepLab export.
  static const int inputSize = 257;

  /// Pascal VOC has 21 classes (20 objects + background).
  static const int numClasses = 21;

  /// A region is considered to "contain a person" if at least this
  /// fraction of its pixels are person-class. Tuned conservatively
  /// so a single misfire pixel doesn't cause a false alarm.
  static const double _personPresenceThreshold = 0.02;

  Interpreter? _interpreter;
  bool _outputIsLogits = false;

  bool get isLoaded => _interpreter != null;

  Future<void> load(String assetPath) async {
    final options = InterpreterOptions()..threads = 2;
    _interpreter = await Interpreter.fromAsset(assetPath, options: options);

    final outShape = _interpreter!.getOutputTensor(0).shape;
    // Logits → 4D, argmax → 3D
    _outputIsLogits = outShape.length == 4;
  }

  /// Reopen an interpreter from a memory address that was created on
  /// another isolate. Used by IsolateInference.
  void loadFromAddress(int address) {
    _interpreter = Interpreter.fromAddress(address);

    final outShape = _interpreter!.getOutputTensor(0).shape;
    _outputIsLogits = outShape.length == 4;
  }

  void close() {
    _interpreter?.close();
    _interpreter = null;
  }

  PathAnalysis? analyze(img.Image source) {
    final interpreter = _interpreter;
    if (interpreter == null) return null;

    final resized = img.copyResize(
      source,
      width: inputSize,
      height: inputSize,
      interpolation: img.Interpolation.linear,
    );

    // Normalised to [-1, 1] — standard for DeepLabV3 mobile exports.
    final input = List.generate(
      1,
      (_) => List.generate(
        inputSize,
        (y) => List.generate(
          inputSize,
          (x) {
            final p = resized.getPixel(x, y);
            return [
              (p.r / 127.5) - 1.0,
              (p.g / 127.5) - 1.0,
              (p.b / 127.5) - 1.0,
            ];
          },
        ),
      ),
    );

    // Build the right output container and run.
    late List<List<int>> mask;

    if (_outputIsLogits) {
      final out = List.generate(
        1,
        (_) => List.generate(
          inputSize,
          (_) => List.generate(
            inputSize,
            (_) => List<double>.filled(numClasses, 0.0),
          ),
        ),
      );

      interpreter.run(input, out);

      mask = List.generate(
        inputSize,
        (y) => List.generate(inputSize, (x) {
          var argmax = 0;
          var best = double.negativeInfinity;

          for (var c = 0; c < numClasses; c++) {
            if (out[0][y][x][c] > best) {
              best = out[0][y][x][c];
              argmax = c;
            }
          }

          return argmax;
        }),
      );
    } else {
      final out = List.generate(
        1,
        (_) => List.generate(
          inputSize,
          (_) => List<int>.filled(inputSize, 0),
        ),
      );

      interpreter.run(input, out);
      mask = out[0];
    }

    return _analyzeMask(mask);
  }

  PathAnalysis _analyzeMask(List<List<int>> mask) {
    // Bottom 50% of frame is the navigation-relevant region.
    final yStart = inputSize ~/ 2;
    final third = inputSize ~/ 3;

    var vehicleVisible = false;

    /// Returns:
    ///   walkable    = fraction of background pixels (kept for diag UI)
    ///   obstacle    = fraction of vehicle+person pixels (hazard signal)
    ///   personFrac  = fraction of person-class pixels (used to flag
    ///                 person presence per-region)
    ({double walkable, double obstacle, double personFrac})
        regionFractions(int xStart, int xEnd) {
      var bgPx = 0;
      var hazardPx = 0;
      var personPx = 0;
      var totalPx = 0;

      for (var y = yStart; y < inputSize; y++) {
        for (var x = xStart; x < xEnd; x++) {
          totalPx++;

          final cls = pascalVocClassFromIndex(mask[y][x]);

          switch (cls) {
            case PascalVocClass.background:
              bgPx++;
              break;
            case PascalVocClass.car:
            case PascalVocClass.bus:
            case PascalVocClass.motorbike:
            case PascalVocClass.bicycle:
            case PascalVocClass.train:
              hazardPx++;
              vehicleVisible = true;
              break;
            case PascalVocClass.person:
              hazardPx++;
              personPx++;
              break;
            default:
              // Other named objects (chair, sofa, pottedplant, etc.)
              // — neither walkable nor a vehicle hazard.
              break;
          }
        }
      }

      if (totalPx == 0) {
        return (walkable: 0.0, obstacle: 0.0, personFrac: 0.0);
      }

      return (
        walkable: bgPx / totalPx,
        obstacle: hazardPx / totalPx,
        personFrac: personPx / totalPx,
      );
    }

    final l = regionFractions(0, third);
    final c = regionFractions(third, third * 2);
    final r = regionFractions(third * 2, inputSize);

    final personLeft = l.personFrac >= _personPresenceThreshold;
    final personCenter = c.personFrac >= _personPresenceThreshold;
    final personRight = r.personFrac >= _personPresenceThreshold;
    final personVisible = personLeft || personCenter || personRight;

    // HONEST MODE: we never claim a walking direction from VOC alone.
    // The consumer (snapshot_screen) treats stop as "say nothing about
    // direction" and will speak only the hazard cues we DO trust
    // (vehicle, person) plus depth and YOLO output.
    const direction = NavigationDirection.stop;

    return PathAnalysis(
      recommendedDirection: direction,
      sidewalkVisible: false,
      roadVisible: false,
      vehicleVisible: vehicleVisible,
      personVisible: personVisible,
      personLeft: personLeft,
      personCenter: personCenter,
      personRight: personRight,
      leftWalkable: l.walkable,
      centerWalkable: c.walkable,
      rightWalkable: r.walkable,
      leftRoad: l.obstacle,
      centerRoad: c.obstacle,
      rightRoad: r.obstacle,
    );
  }
}