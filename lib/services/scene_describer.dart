import '../models/detection.dart';
import '../models/scene_analysis.dart';
import '../utils/coco_labels.dart';
import '../utils/oiv7_labels.dart';

/// Produces blind-friendly spoken descriptions from a SceneAnalysis.
///
/// - Sorts closest-first
/// - Dedupes overlapping bboxes by IoU > 0.30
/// - Groups by pretty label
/// - Max 4 objects per utterance
/// - Distance zones (very close / close / medium / far)
/// - Direction (left / ahead / right)
///
/// **Honest mode (Phase 5)**: detections whose `distanceSource` is
/// 'unreliable' (loose-prior classes like suitcase / bus / truck when
/// MiDaS scale-shift fusion couldn't run) speak DIRECTION ONLY — no
/// metres. This avoids announcing "suitcase at 1.4 metres" when the
/// suitcase is actually 2.4m away and the system has no way to know.
///
/// We still RANK these detections by distance (so closer objects
/// announce first) — we just don't speak the number. This is the
/// honest engineering decision: better to say less than to say
/// something confidently wrong to a blind user navigating a real
/// space.
class SceneDescriber {
  /// Distance sources we consider trustworthy enough to speak as
  /// metre values. Anything outside this set gets direction-only
  /// announcements (no number spoken).
  ///
  /// 'pinhole' — tight-prior class, classical estimate.
  /// 'pinhole-clipped' — touched frame edge, still a real measurement.
  /// 'hybrid' — pinhole + MiDaS fusion agreed, best confidence.
  /// 'midas' — fusion fit available, prior was missing.
  ///
  /// NOT trustworthy: 'unreliable' (loose-prior, no fusion fit),
  /// 'category-only' (no prior at all), 'none' (failed).
  static const Set<String> _trustedDistanceSources = <String>{
    'pinhole',
    'pinhole-clipped',
    'hybrid',
    'midas',
  };

  static String describe(SceneAnalysis a, {int maxObjects = 4}) {
    if (a.detections.isEmpty) {
      return 'No recognizable objects detected. Try pointing the camera '
          'differently or moving closer.';
    }

    final enriched = a.detections.map((d) {
      return _Announceable(
        detection: d,
        zone: zoneFromMeters(d.distanceMeters, edgeClipped: d.touchesEdge),
        direction: directionFromCenter(d.cx, a.imageWidth),
        pretty: _pretty(d.label),
      );
    }).toList();

    int zoneRank(DistanceZone z) {
      switch (z) {
        case DistanceZone.veryClose: return 0;
        case DistanceZone.close: return 1;
        case DistanceZone.medium: return 2;
        case DistanceZone.far: return 3;
        case DistanceZone.veryFar: return 4;
        case DistanceZone.unknown: return 5;
      }
    }

    enriched.sort((x, y) {
      final c = zoneRank(x.zone).compareTo(zoneRank(y.zone));
      if (c != 0) return c;
      final xd = x.detection.distanceMeters.isFinite
          ? x.detection.distanceMeters : 1e9;
      final yd = y.detection.distanceMeters.isFinite
          ? y.detection.distanceMeters : 1e9;
      return xd.compareTo(yd);
    });

    // Dedupe by IoU within same pretty label
    final dedupedByIoU = <_Announceable>[];
    for (final e in enriched) {
      bool isDup = false;
      for (final k in dedupedByIoU) {
        if (k.pretty == e.pretty && _iou(e.detection, k.detection) > 0.30) {
          isDup = true; break;
        }
      }
      if (!isDup) dedupedByIoU.add(e);
    }

    // Group by pretty label, keep closest representative
    final Map<String, _AnnounceGroup> groups = {};
    for (final e in dedupedByIoU) {
      final g = groups[e.pretty];
      if (g == null) {
        groups[e.pretty] = _AnnounceGroup(e);
      } else {
        g.count++;
        final currentRank = zoneRank(g.first.zone);
        final newRank = zoneRank(e.zone);
        if (newRank < currentRank) {
          g.first = e;
        } else if (newRank == currentRank &&
            e.detection.distanceMeters.isFinite &&
            g.first.detection.distanceMeters.isFinite &&
            e.detection.distanceMeters < g.first.detection.distanceMeters) {
          g.first = e;
        }
      }
    }

    final sorted = groups.values.toList()
      ..sort((x, y) {
        final c = zoneRank(x.first.zone).compareTo(zoneRank(y.first.zone));
        if (c != 0) return c;
        final xd = x.first.detection.distanceMeters.isFinite
            ? x.first.detection.distanceMeters : 1e9;
        final yd = y.first.detection.distanceMeters.isFinite
            ? y.first.detection.distanceMeters : 1e9;
        return xd.compareTo(yd);
      });

    final kept = sorted.take(maxObjects).toList();
    final extraCount = sorted.length - kept.length;

    final sb = StringBuffer();
    sb.write('Detected ');
    sb.write(_countPhrase(sorted.length, 'object', 'objects'));
    sb.write('. ');

    for (int i = 0; i < kept.length; i++) {
      sb.write(_describeGroup(kept[i]));
      sb.write('. ');
    }

    if (extraCount > 0) {
      sb.write('And ');
      sb.write(_countPhrase(extraCount, 'more', 'more'));
      sb.write('.');
    }

    return sb.toString().trim();
  }

  static String _describeGroup(_AnnounceGroup g) {
    final d = g.first.detection;
    final labelPhrase = g.count > 1
        ? '${g.count} ${_pluralize(g.first.pretty)}'
        : _withArticle(g.first.pretty);

    // Honest mode: if the distance source isn't trustworthy, speak
    // direction only — no metre value. The ranking by zone already
    // happened above, so closer objects still announce first; we
    // just don't put a confidently-wrong number in the user's ear.
    final trustedDistance =
        _trustedDistanceSources.contains(d.distanceSource);

    String distancePhrase;
    if (d.touchesEdge || g.first.zone == DistanceZone.veryClose) {
      // Edge-clipped or very-close detections always get the urgency
      // phrasing even if the number is unreliable — "very close" is
      // a categorical statement that doesn't depend on metric accuracy.
      distancePhrase = 'very close';
    } else if (!trustedDistance) {
      // Loose-prior class with no MiDaS fusion correction. We have a
      // distanceMeters value (used internally for ranking) but we
      // refuse to speak it — better to say nothing about distance
      // than to say a wrong number with confidence.
      distancePhrase = '';
    } else if (g.first.zone == DistanceZone.close) {
      distancePhrase = 'close, about '
          '${d.distanceMeters.toStringAsFixed(1)} meters away';
    } else if (g.first.zone == DistanceZone.unknown) {
      distancePhrase = '';
    } else {
      distancePhrase =
          'about ${d.distanceMeters.toStringAsFixed(1)} meters away';
    }

    final directionPhrase = g.first.direction.speech;

    if (distancePhrase.isEmpty) {
      return '$labelPhrase $directionPhrase';
    }
    return '$labelPhrase $distancePhrase, $directionPhrase';
  }

  static String _pretty(String raw) {
    if (raw.isEmpty) return raw;
    if (raw == raw.toLowerCase()) {
      return prettyLabel(raw);
    }
    return prettyOiv7(raw);
  }

  static String _withArticle(String s) {
    if (s.isEmpty) return s;
    final first = s[0].toLowerCase();
    return 'aeiou'.contains(first) ? 'an $s' : 'a $s';
  }

  static String _pluralize(String s) {
    if (s.endsWith('s') || s.endsWith('x') || s.endsWith('z')) return '${s}es';
    if (s.endsWith('y') && s.length > 1 &&
        !'aeiou'.contains(s[s.length - 2])) {
      return '${s.substring(0, s.length - 1)}ies';
    }
    return '${s}s';
  }

  static String _countPhrase(int n, String singular, String plural) {
    if (n == 1) return '1 $singular';
    return '$n $plural';
  }

  static double _iou(Detection a, Detection b) {
    final x1 = a.x1 > b.x1 ? a.x1 : b.x1;
    final y1 = a.y1 > b.y1 ? a.y1 : b.y1;
    final x2 = a.x2 < b.x2 ? a.x2 : b.x2;
    final y2 = a.y2 < b.y2 ? a.y2 : b.y2;
    final iw = (x2 - x1).clamp(0.0, double.infinity);
    final ih = (y2 - y1).clamp(0.0, double.infinity);
    final inter = iw * ih;
    final aw = a.x2 - a.x1, ah = a.y2 - a.y1;
    final bw = b.x2 - b.x1, bh = b.y2 - b.y1;
    final union = aw * ah + bw * bh - inter;
    return union <= 0 ? 0 : inter / union;
  }
}

class _Announceable {
  final Detection detection;
  final DistanceZone zone;
  final Direction direction;
  final String pretty;
  _Announceable({
    required this.detection,
    required this.zone,
    required this.direction,
    required this.pretty,
  });
}

class _AnnounceGroup {
  _Announceable first;
  int count = 1;
  _AnnounceGroup(this.first);
}