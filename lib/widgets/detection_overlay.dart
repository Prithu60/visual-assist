import 'package:flutter/material.dart';
import '../models/scene_analysis.dart';

class DetectionOverlay extends StatelessWidget {
  final SceneAnalysis analysis;
  const DetectionOverlay({super.key, required this.analysis});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _OverlayPainter(analysis),
      size: Size.infinite,
    );
  }
}

class _OverlayPainter extends CustomPainter {
  final SceneAnalysis analysis;
  _OverlayPainter(this.analysis);

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / analysis.imageWidth;
    final scaleY = size.height / analysis.imageHeight;

    final boxPaint = Paint()
      ..color = Colors.greenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    final bgPaint = Paint()..color = Colors.black54;

    for (final d in analysis.detections) {
      final rect = Rect.fromLTRB(
        d.x1 * scaleX,
        d.y1 * scaleY,
        d.x2 * scaleX,
        d.y2 * scaleY,
      );
      canvas.drawRect(rect, boxPaint);

      final tp = TextPainter(
        text: TextSpan(
          text: ' ${d.label} ${d.confidence.toStringAsFixed(2)} ',
          style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final labelRect = Rect.fromLTWH(
          rect.left, rect.top - tp.height, tp.width, tp.height);
      canvas.drawRect(labelRect, bgPaint);
      tp.paint(canvas, Offset(rect.left, rect.top - tp.height));
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) =>
      old.analysis != analysis;
}