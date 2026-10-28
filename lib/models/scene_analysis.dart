import 'depth_analysis.dart';
import 'detection.dart';
import 'segmentation_result.dart';

class SceneAnalysis {
  final int imageWidth;
  final int imageHeight;
  final List<Detection> detections;
  final int latencyMs;
  final double? scaleShiftS;
  final double? scaleShiftT;
  final DepthAnalysis? depth;
  final int? depthLatencyMs;
  final PathAnalysis? path;
  final int? segLatencyMs;

  const SceneAnalysis({
    required this.imageWidth,
    required this.imageHeight,
    required this.detections,
    required this.latencyMs,
    this.scaleShiftS,
    this.scaleShiftT,
    this.depth,
    this.depthLatencyMs,
    this.path,
    this.segLatencyMs,
  });
}