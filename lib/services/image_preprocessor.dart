import 'package:image/image.dart' as img;

class LetterboxResult {
  final img.Image image;
  final double scale;
  final double padX;
  final double padY;
  const LetterboxResult({
    required this.image,
    required this.scale,
    required this.padX,
    required this.padY,
  });
}

LetterboxResult letterbox(img.Image src, int targetSize) {
  final scale = (targetSize / src.width).clamp(0.0, double.infinity) <
          (targetSize / src.height)
      ? targetSize / src.width
      : targetSize / src.height;
  final newW = (src.width * scale).round();
  final newH = (src.height * scale).round();
  final padX = ((targetSize - newW) / 2).floor().toDouble();
  final padY = ((targetSize - newH) / 2).floor().toDouble();

  final resized = img.copyResize(src,
      width: newW, height: newH, interpolation: img.Interpolation.linear);

  final canvas = img.Image(width: targetSize, height: targetSize);
  img.fill(canvas, color: img.ColorRgb8(114, 114, 114));
  img.compositeImage(canvas, resized,
      dstX: padX.toInt(), dstY: padY.toInt());

  return LetterboxResult(
    image: canvas,
    scale: scale,
    padX: padX,
    padY: padY,
  );
}