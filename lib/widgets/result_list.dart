import 'package:flutter/material.dart';
import '../models/scene_analysis.dart';

class ResultList extends StatelessWidget {
  final SceneAnalysis analysis;
  const ResultList({super.key, required this.analysis});

  @override
  Widget build(BuildContext context) {
    if (analysis.detections.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.search_off, size: 60, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('No objects detected.',
                style: TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            Text('Latency: ${analysis.latencyMs} ms',
                style: const TextStyle(fontSize: 14, color: Colors.grey)),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            '${analysis.detections.length} objects · ${analysis.latencyMs} ms',
            style: const TextStyle(fontSize: 14, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: analysis.detections.length,
            itemBuilder: (ctx, i) {
              final d = analysis.detections[i];
              final dist = d.distanceMeters.isFinite
                  ? '${d.distanceMeters.toStringAsFixed(1)} m'
                  : '—';
              return ListTile(
                leading: CircleAvatar(child: Text('${i + 1}')),
                title: Text(d.label,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                subtitle: Text(
                    'conf=${d.confidence.toStringAsFixed(2)} · $dist '
                    '${d.touchesEdge ? "· edge" : ""}'),
              );
            },
          ),
        ),
      ],
    );
  }
}