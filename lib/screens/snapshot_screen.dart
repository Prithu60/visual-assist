import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:vibration/vibration.dart';

import '../models/depth_analysis.dart';
import '../models/detection.dart';
import '../models/scene_analysis.dart';
import '../models/segmentation_result.dart';
import '../services/api_keys_service.dart';
import '../services/camera_intrinsics.dart';
import '../services/emergency_contacts.dart';
import '../services/gemini_scene_service.dart';
import '../services/isolate_inference.dart';
import '../services/scene_describer.dart';
import '../services/sos_service.dart';
import '../services/torch_service.dart';
import '../services/tts_service.dart';
import '../widgets/detection_overlay.dart';
import '../widgets/result_list.dart';
import '../widgets/sos_button.dart';
import 'emergency_setup_screen.dart';
import 'gemini_settings_screen.dart';

class SnapshotScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const SnapshotScreen({super.key, required this.cameras});

  @override
  State<SnapshotScreen> createState() => _SnapshotScreenState();
}

class _SnapshotScreenState extends State<SnapshotScreen>
    with WidgetsBindingObserver {
  // ---- Distance whitelist ------------------------------------------------
  static const Set<String> _distanceWhitelist = <String>{
    'person',
    'car', 'bus', 'truck', 'motorcycle', 'bicycle',
    'chair', 'couch', 'bed', 'dining table',
    'laptop', 'tv',
    'refrigerator', 'oven', 'microwave', 'toilet',
    'bottle',
    'stop sign', 'traffic light', 'fire hydrant',
    'parking meter', 'bench',
  };

  // ---- Live haptic mode tuning -------------------------------------------
  static const Duration _liveTickPeriod = Duration(milliseconds: 1500);
  static const Duration _liveVibrationCooldown = Duration(seconds: 2);
  static const double _liveDistanceThresholdMeters = 1.5;

  /// Strong pulse for live-mode obstacle alerts.
  static const int _liveVibrationMs = 400;

  /// Short pulse for confirmation feedback (capture button, mode toggle).
  static const int _confirmVibrationMs = 60;

  /// Multi-frame voting threshold. The trigger label must appear in
  /// this many consecutive ticks before live mode actually buzzes.
  /// Filters one-frame YOLO hallucinations (a coat momentarily
  /// classified as a person, etc.) at the cost of doubling the worst-
  /// case warning latency.
  static const int _votingFramesRequired = 2;

  // ---- existing fields -----------------------------------------------------
  CameraController? _controller;
  final IsolateInference _inference = IsolateInference();
  final TtsService _tts = TtsService();
  final TorchService _torch = TorchService();
  bool _initialized = false;
  bool _busy = false;
  SceneAnalysis? _result;
  CameraIntrinsics? _intrinsics;

  String _initStatus = 'Starting...';
  String? _initError;

  // ---- Phase 1 SOS ---------------------------------------------------------
  late final SosService _sos;
  bool _sosConfigured = false;

  // ---- Phase 4 Gemini ------------------------------------------------------
  late final GeminiSceneService _gemini;
  Uint8List? _lastJpegBytes;
  bool _describing = false;

  // ---- Live haptic mode state ---------------------------------------------
  bool _liveModeOn = false;
  Timer? _liveTimer;
  bool _liveTickInFlight = false;
  DateTime _lastLiveVibration =
      DateTime.fromMillisecondsSinceEpoch(0);
  bool _liveAlertFlash = false;
  String _lastLiveTrigger = '';

  /// Most recent live-mode tick's "candidate trigger label" (or null
  /// if no candidate). Used for multi-frame voting — we only fire when
  /// the same label appears in the current AND the previous tick.
  ///
  /// Why label-only and not a richer fingerprint:
  ///   * Bounding box position changes frame-to-frame even on a static
  ///     object due to YOLO output noise.
  ///   * Distance estimates wobble ±10-15% between frames.
  ///   * Class identity is the most stable per-frame signal we have,
  ///     so it's the cleanest thing to vote on.
  String? _previousTickCandidate;

  bool _hasVibrator = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sos = SosService(tts: _tts);
    _gemini = GeminiSceneService();
    _init();
  }

  /// Auto-disable torch when app goes to background. The OS may force
  /// the camera to release anyway, but explicitly setting flash off
  /// keeps our state in sync so the button shows the right icon when
  /// we return.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _torch.forceOff();
    }
  }

  Future<void> _init() async {
    try {
      if (widget.cameras.isEmpty) throw 'No cameras available';

      setState(() => _initStatus = '1/4 Creating camera controller...');
      _controller = CameraController(
        widget.cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      setState(() => _initStatus = '2/4 Initializing camera...');
      await _controller!.initialize();

      // Attach torch service AFTER camera is initialized. The torch
      // depends on the controller being ready to accept setFlashMode.
      _torch.attach(_controller!);

      setState(() => _initStatus = '3/4 Loading YOLO model...');
      await _inference.start();

      setState(() => _initStatus = '4/4 Fetching camera intrinsics...');
      _intrinsics = await CameraIntrinsicsService.fetch(
        imageWidth: _controller!.value.previewSize?.height.toInt() ?? 720,
        imageHeight: _controller!.value.previewSize?.width.toInt() ?? 1280,
      );

      await _tts.init();

      try {
        _hasVibrator = (await Vibration.hasVibrator()) ?? false;
        // ignore: avoid_print
        print('[Vibration] hasVibrator=$_hasVibrator');
      } catch (e) {
        // ignore: avoid_print
        print('[Vibration] hasVibrator check failed: $e');
        _hasVibrator = false;
      }

      await _refreshSosConfigured();
      await _maybeInitGemini();

      if (mounted) {
        setState(() {
          _initialized = true;
          _initStatus = 'Ready';
        });
      }

      await _tts.speak(
        'Ready. Tap the capture button to describe the scene.',
      );
    } catch (e, st) {
      // ignore: avoid_print
      print('=== INIT ERROR === $e\n$st');

      if (mounted) {
        setState(() {
          _initError = '$e';
          _initStatus = 'FAILED at: $_initStatus';
        });
      }

      try {
        await _tts.speak('Initialization failed.');
      } catch (_) {}
    }
  }

  Future<void> _refreshSosConfigured() async {
    try {
      final cfg = await EmergencyContactsService.load();
      if (mounted) {
        setState(() => _sosConfigured = cfg != null && cfg.isUsable);
      }
    } catch (e) {
      // ignore: avoid_print
      print('=== SOS CONFIG LOAD === $e');
    }
  }

  Future<void> _maybeInitGemini() async {
    try {
      final key = await ApiKeysService.readGeminiKey();
      if (key.isNotEmpty) {
        await _gemini.initialize();
      }
    } catch (e) {
      // ignore: avoid_print
      print('=== GEMINI INIT === $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Torch handler
  // ---------------------------------------------------------------------------

  /// Tap handler for the torch button. Toggles flash + speaks state
  /// confirmation (helpful for the target user who can't see the icon).
  Future<void> _onTorchTap() async {
    final result = await _torch.toggle();
    if (result == null) {
      await _tts.speak('Torch unavailable.');
      return;
    }
    await _vibrateConfirm();
    await _tts.speak(result ? 'Torch on.' : 'Torch off.');
  }

  // ---------------------------------------------------------------------------
  // Vibration helpers
  // ---------------------------------------------------------------------------

  Future<void> _vibrateAlert() async {
    if (!_hasVibrator) return;
    try {
      await Vibration.vibrate(duration: _liveVibrationMs, amplitude: 255);
    } catch (e) {
      // ignore: avoid_print
      print('[Vibration] alert error: $e');
    }
  }

  Future<void> _vibrateConfirm() async {
    if (!_hasVibrator) return;
    try {
      await Vibration.vibrate(duration: _confirmVibrationMs);
    } catch (e) {
      // ignore: avoid_print
      print('[Vibration] confirm error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Spoken-phrase builders (used for the local Capture path)
  // ---------------------------------------------------------------------------

  String _depthPhraseFor(DepthAnalysis? depth) {
    if (depth == null) return '';

    final veryClose = <String>[];
    if (depth.left.zone == ObstacleZone.veryClose) veryClose.add('left');
    if (depth.center.zone == ObstacleZone.veryClose) veryClose.add('center');
    if (depth.right.zone == ObstacleZone.veryClose) veryClose.add('right');

    if (veryClose.isNotEmpty) {
      return 'Stop. Obstacle very close on the ${veryClose.join(' and ')}.';
    }

    final near = <String>[];
    if (depth.left.zone == ObstacleZone.near) near.add('left');
    if (depth.center.zone == ObstacleZone.near) near.add('center');
    if (depth.right.zone == ObstacleZone.near) near.add('right');

    if (near.isNotEmpty) {
      return 'Obstacle close on the ${near.join(' and ')}.';
    }
    return '';
  }

  String _pathPhraseFor(PathAnalysis? path) {
    if (path == null) return '';

    if (path.vehicleVisible) {
      return 'Vehicle visible. Take care.';
    }

    if (path.personVisible) {
      if (path.personCenter) return 'Person ahead.';
      if (path.personLeft && !path.personRight) return 'Person on your left.';
      if (path.personRight && !path.personLeft) return 'Person on your right.';
      return 'Person nearby.';
    }
    return '';
  }

  // ---------------------------------------------------------------------------
  // CAPTURE mode
  // ---------------------------------------------------------------------------
  Future<void> _capture() async {
    if (!_initialized || _busy || _controller == null) return;

    final wasLive = _liveModeOn;
    if (wasLive) {
      _stopLiveTimer();
    }

    setState(() => _busy = true);
    await _vibrateConfirm();
    await _tts.speak('Analyzing');

    try {
      final XFile shot = await _controller!.takePicture();
      final bytes = await shot.readAsBytes();
      _lastJpegBytes = bytes;

      final result = await _inference.analyseJpeg(
        jpegBytes: bytes,
        intrinsics: _intrinsics!,
      );

      if (mounted) setState(() => _result = result);

      final fullSentence = _composeAnnouncement(result);
      await _tts.speak(fullSentence);
    } catch (e) {
      // ignore: avoid_print
      print('=== CAPTURE ERROR === $e');
      await _tts.speak('Error capturing. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
      if (wasLive && mounted && _liveModeOn) {
        _startLiveTimer();
      }
    }
  }

  String _composeAnnouncement(SceneAnalysis result) {
    final announcement = SceneDescriber.describe(result, maxObjects: 4);
    final depthPhrase = _depthPhraseFor(result.depth);

    final depthIsUrgent = result.depth?.hasRelevantObstacle ?? false;
    final pathPhrase = depthIsUrgent ? '' : _pathPhraseFor(result.path);

    final parts = <String>[
      if (pathPhrase.isNotEmpty) pathPhrase,
      if (depthPhrase.isNotEmpty) depthPhrase,
      announcement,
    ];
    return parts.join(' ');
  }

  // ---------------------------------------------------------------------------
  // LIVE haptic mode — multi-frame voting on YOLO measured distance
  //
  // Trigger pipeline per tick:
  //   1. Find a "candidate" — the closest whitelisted detection within
  //      the distance threshold (or any edge-clipped whitelisted
  //      detection).
  //   2. Compare candidate's class label to the previous tick's
  //      candidate label.
  //   3. Only fire vibration if both ticks agreed on the same label.
  //
  // This means a single-frame YOLO hallucination (e.g. a draped coat
  // momentarily classified as "person" at 0.6 confidence) is filtered
  // out — the next tick almost always corrects it.
  //
  // Trade-offs documented at the top of the class:
  //   * Worst-case latency 3s instead of 1.5s.
  //   * Object briefly leaving frame resets the vote (safer behaviour
  //     in motion than the alternative which would buzz on every
  //     return).
  //   * A consistent hallucination (e.g., a coat that looks like a
  //     person from THIS specific angle, in two frames in a row) will
  //     still buzz — voting cuts noisy hallucinations but not stable
  //     ones. A 3-frame vote would help further but compounds the
  //     latency cost.
  // ---------------------------------------------------------------------------

  void _toggleLiveMode() {
    if (_liveModeOn) {
      _disableLiveMode();
    } else {
      _enableLiveMode();
    }
  }

  void _enableLiveMode() {
    if (_liveModeOn || !_initialized || _controller == null) return;

    // ignore: avoid_print
    print('[LiveMode] enabled');
    setState(() => _liveModeOn = true);

    // Reset the voting state so a new live session doesn't fire on
    // stale data from a previous session.
    _previousTickCandidate = null;

    _vibrateConfirm();
    _startLiveTimer();
  }

  void _disableLiveMode() {
    if (!_liveModeOn) return;

    // ignore: avoid_print
    print('[LiveMode] disabled');
    _stopLiveTimer();
    _previousTickCandidate = null;
    if (mounted) setState(() => _liveModeOn = false);
  }

  void _startLiveTimer() {
    _liveTimer?.cancel();
    _liveTimer = Timer.periodic(_liveTickPeriod, (_) => _liveTick());
  }

  void _stopLiveTimer() {
    _liveTimer?.cancel();
    _liveTimer = null;
  }

  Future<void> _liveTick() async {
    if (!_liveModeOn || !mounted || _controller == null) return;
    if (_liveTickInFlight) return;
    if (_busy) return;

    _liveTickInFlight = true;
    try {
      final XFile shot = await _controller!.takePicture();
      final bytes = await shot.readAsBytes();

      final result = await _inference.analyseJpeg(
        jpegBytes: bytes,
        intrinsics: _intrinsics!,
      );

      // ---- Step 1: find the candidate trigger this tick -----------------
      Detection? candidate;
      for (final d in result.detections) {
        if (!_distanceWhitelist.contains(d.label)) continue;

        if (d.touchesEdge) {
          candidate = d;
          break;
        }

        if (!d.distanceMeters.isFinite) continue;
        if (d.distanceMeters <= 0) continue;
        if (d.distanceMeters >= _liveDistanceThresholdMeters) continue;

        candidate = d;
        break;
      }

      // ---- Step 2: multi-frame voting ----------------------------------
      // We need this tick's candidate AND the previous tick's
      // candidate to be the same class. Both nullness and label
      // mismatch should reset/fail the vote.
      final candidateLabel = candidate?.label;
      final voteAgrees = candidateLabel != null &&
          _previousTickCandidate == candidateLabel;

      // Update history BEFORE firing — even if we fire, the next tick
      // should compare against this tick's candidate, not the one
      // before it. This prevents a 3-tick chain from auto-firing on
      // every single tick after the second one (which would defeat
      // the cooldown's purpose).
      _previousTickCandidate = candidateLabel;

      if (candidate == null) {
        if (_votingFramesRequired > 1) {
          // ignore: avoid_print
          if (result.detections.isNotEmpty) {
            // ignore: avoid_print
            print('[LiveMode] no candidate this tick — '
                'detections=${result.detections.map((d) => "${d.label}@${d.distanceMeters.toStringAsFixed(1)}m${d.touchesEdge ? "(edge)" : ""}").join(", ")}');
          }
        }
        return;
      }

      if (!voteAgrees) {
        // ignore: avoid_print
        print('[LiveMode] candidate=$candidateLabel '
            'previous=${_previousTickCandidate == candidateLabel ? "match" : "mismatch (was ${_previousTickCandidate ?? "none"})"} '
            '— vote not yet, waiting for confirmation');
        return;
      }

      // ---- Step 3: vote agrees, check cooldown ------------------------
      final now = DateTime.now();
      if (now.difference(_lastLiveVibration) < _liveVibrationCooldown) {
        return;
      }
      _lastLiveVibration = now;

      await _vibrateAlert();

      final desc = candidate.touchesEdge
          ? '${candidate.label} very close (edge)'
          : '${candidate.label} at ${candidate.distanceMeters.toStringAsFixed(1)}m';

      // ignore: avoid_print
      print('[LiveMode] vibrated (vote confirmed): $desc');

      if (mounted) {
        setState(() {
          _liveAlertFlash = true;
          _lastLiveTrigger = desc;
        });
        Future.delayed(const Duration(milliseconds: 1200), () {
          if (mounted) setState(() => _liveAlertFlash = false);
        });
      }
    } catch (e) {
      // ignore: avoid_print
      print('[LiveMode] tick error: $e');
    } finally {
      _liveTickInFlight = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Edge-cloud fusion: build "facts" string for Gemini
  // ---------------------------------------------------------------------------

  String _buildFactsForGemini(SceneAnalysis result) {
    final lines = <String>[];

    final detections = List<Detection>.from(result.detections);
    detections.sort((a, b) {
      final ad = a.distanceMeters.isFinite ? a.distanceMeters : 1e9;
      final bd = b.distanceMeters.isFinite ? b.distanceMeters : 1e9;
      return ad.compareTo(bd);
    });

    final spokenLabels = <String>{};
    for (final d in detections) {
      if (spokenLabels.contains(d.label)) continue;
      spokenLabels.add(d.label);

      final dir = _directionWord(d.cx, result.imageWidth);
      final allowsDistance = _distanceWhitelist.contains(d.label);
      final distanceFinite = d.distanceMeters.isFinite &&
          d.distanceMeters > 0 &&
          d.distanceMeters < 30 &&
          !d.touchesEdge;

      if (d.touchesEdge) {
        lines.add('- ${d.label} very close, $dir');
      } else if (allowsDistance && distanceFinite) {
        final m = d.distanceMeters.toStringAsFixed(1);
        lines.add('- ${d.label} at $m metres, $dir');
      } else {
        lines.add('- ${d.label}, $dir');
      }

      if (lines.length >= 6) break;
    }

    final depth = result.depth;
    if (depth != null) {
      final closeSides = <String>[];
      if (depth.left.zone == ObstacleZone.veryClose ||
          depth.left.zone == ObstacleZone.near) {
        closeSides.add('left');
      }
      if (depth.center.zone == ObstacleZone.veryClose ||
          depth.center.zone == ObstacleZone.near) {
        closeSides.add('center');
      }
      if (depth.right.zone == ObstacleZone.veryClose ||
          depth.right.zone == ObstacleZone.near) {
        closeSides.add('right');
      }
      if (closeSides.isNotEmpty) {
        lines.add('- depth: close obstacle on ${closeSides.join(' and ')}');
      }
    }

    final path = result.path;
    if (path != null) {
      if (path.vehicleVisible) {
        lines.add('- segmentation: vehicle visible');
      }
      if (path.personVisible) {
        final where = <String>[];
        if (path.personLeft) where.add('left');
        if (path.personCenter) where.add('center');
        if (path.personRight) where.add('right');
        lines.add(
          '- segmentation: person on ${where.isEmpty ? "scene" : where.join(" and ")}',
        );
      }
    }

    if (lines.isEmpty) return '';

    return 'On-device sensor measurements for this photo:\n${lines.join('\n')}';
  }

  String _directionWord(double cxPixels, int imageWidth) {
    final n = imageWidth > 0 ? cxPixels / imageWidth : 0.5;
    if (n < 0.33) return 'on the left';
    if (n > 0.67) return 'on the right';
    return 'ahead';
  }

  // ---------------------------------------------------------------------------
  // Phase 4 — Gemini scene description on the last captured JPEG
  // ---------------------------------------------------------------------------
  Future<void> _describeWithGemini() async {
    if (_describing) return;

    if (_lastJpegBytes == null) {
      await _tts.speak('Take a picture first.');
      return;
    }

    setState(() => _describing = true);
    await _vibrateConfirm();
    await _tts.speak('Describing the scene in detail.');

    try {
      final key = await ApiKeysService.readGeminiKey();
      if (key.isEmpty) {
        await _tts.speak(
          'Gemini API key not set. Open the menu to add a key.',
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'No Gemini API key set. Use the menu → Gemini API Key.',
              ),
            ),
          );
        }
        return;
      }

      if (!_gemini.isReady) {
        await _gemini.initialize();
      }

      final cached = _result;
      final facts = (cached != null) ? _buildFactsForGemini(cached) : null;

      if (facts != null && facts.isNotEmpty) {
        // ignore: avoid_print
        print('=== GEMINI FACTS ===\n$facts');
      }

      final description =
          await _gemini.describe(_lastJpegBytes!, facts: facts);
      await _tts.speak(description);
    } catch (e, st) {
      // ignore: avoid_print
      print('=== GEMINI DESCRIBE ERROR === $e\n$st');

      await _speakLocalFallbackDescription(e);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isCloudUnavailable(e)
                  ? 'Cloud unavailable; used on-device description.'
                  : 'Cloud error; used on-device description.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _describing = false);
    }
  }

  Future<void> _speakLocalFallbackDescription(Object cloudError) async {
    final lead = _isCloudUnavailable(cloudError)
        ? 'Cloud service unavailable. Using on-device description.'
        : 'Cloud description failed. Using on-device description.';

    final cached = _result;
    if (cached == null) {
      await _tts.speak(
        '$lead Tap the capture button to analyse the scene on-device.',
      );
      return;
    }

    final local = _composeAnnouncement(cached);
    await _tts.speak('$lead $local');
  }

  bool _isCloudUnavailable(Object e) {
    if (e is GenerativeAIException) {
      final msg = e.toString().toLowerCase();
      return msg.contains('503') ||
          msg.contains('overloaded') ||
          msg.contains('unavailable') ||
          msg.contains('quota') ||
          msg.contains('429');
    }
    final s = e.toString().toLowerCase();
    return s.contains('socketexception') ||
        s.contains('handshake') ||
        s.contains('timeout') ||
        s.contains('host lookup');
  }

  // ---------------------------------------------------------------------------
  // Phase 1 — SOS trigger
  // ---------------------------------------------------------------------------
  Future<void> _onSosConfirmed() async {
    try {
      final result = await _sos.trigger();
      // ignore: avoid_print
      print('=== SOS RESULT === $result');
    } catch (e, st) {
      // ignore: avoid_print
      print('=== SOS ERROR === $e\n$st');

      await _tts.speak('Emergency send failed.');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('SOS error: $e')),
        );
      }
    }
  }

  Future<void> _openEmergencySetup() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EmergencySetupScreen(tts: _tts),
      ),
    );

    await _refreshSosConfigured();
  }

  Future<void> _openGeminiSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GeminiSettingsScreen(tts: _tts),
      ),
    );

    await _maybeInitGemini();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopLiveTimer();
    // Force torch off and detach BEFORE disposing the controller —
    // otherwise the torch service is left holding a reference to a
    // dead controller, and on some devices the LED stays on briefly.
    _torch.forceOff();
    _torch.detach();
    _controller?.dispose();
    _inference.stop();
    _tts.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Initialization Failed')),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error, color: Colors.red, size: 80),
                const SizedBox(height: 16),
                Text(
                  _initStatus,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Error:', style: TextStyle(fontSize: 16)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade900,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _initError!,
                    style: const TextStyle(
                      fontSize: 14,
                      fontFamily: 'monospace',
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Go Back'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!_initialized) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(_initStatus, style: const TextStyle(fontSize: 18)),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Visual Assist'),
        actions: [
          // Torch toggle in the app bar — using AnimatedBuilder so it
          // rebuilds whenever TorchService notifies (which happens on
          // attach/detach/toggle/forceOff). This way the icon and
          // colour always reflect the actual hardware state.
          AnimatedBuilder(
            animation: _torch,
            builder: (context, _) {
              if (!_torch.isSupported) return const SizedBox.shrink();
              return Semantics(
                label: _torch.isOn
                    ? 'Torch on, tap to turn off'
                    : 'Torch off, tap to turn on',
                toggled: _torch.isOn,
                child: IconButton(
                  tooltip: _torch.isOn ? 'Turn torch off' : 'Turn torch on',
                  icon: Icon(
                    _torch.isOn ? Icons.flash_on : Icons.flash_off,
                    color: _torch.isOn ? Colors.amber : Colors.white,
                  ),
                  onPressed: _onTorchTap,
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Row(
              children: [
                Text(
                  _liveModeOn ? 'LIVE' : 'CAPTURE',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: _liveModeOn ? Colors.amber : Colors.white,
                  ),
                ),
                Semantics(
                  label: _liveModeOn
                      ? 'Live haptic mode on, tap to disable'
                      : 'Live haptic mode off, tap to enable',
                  toggled: _liveModeOn,
                  child: Switch(
                    value: _liveModeOn,
                    activeColor: Colors.amber,
                    onChanged: (_) => _toggleLiveMode(),
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'Settings',
            onSelected: (value) {
              switch (value) {
                case 'emergency':
                  _openEmergencySetup();
                  break;
                case 'gemini':
                  _openGeminiSettings();
                  break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'emergency',
                child: ListTile(
                  leading: Icon(Icons.emergency, color: Colors.red),
                  title: Text('Emergency setup'),
                ),
              ),
              PopupMenuItem(
                value: 'gemini',
                child: ListTile(
                  leading: Icon(Icons.key),
                  title: Text('Gemini API key'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          AspectRatio(
            aspectRatio: _controller!.value.aspectRatio,
            child: Stack(
              children: <Widget>[
                CameraPreview(_controller!),
                if (_result != null)
                  Positioned.fill(child: DetectionOverlay(analysis: _result!)),
                if (_liveAlertFlash)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Colors.amber,
                            width: 8,
                          ),
                        ),
                        alignment: Alignment.topCenter,
                        padding: const EdgeInsets.only(top: 12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.amber.shade700,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            _lastLiveTrigger.isEmpty
                                ? 'OBSTACLE'
                                : _lastLiveTrigger.toUpperCase(),
                            style: const TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_liveModeOn)
                  Positioned(
                    left: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        '● LIVE',
                        style: TextStyle(
                          color: Colors.amber,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                // Torch indicator in the corner of the preview — gives
                // sighted helpers a visual confirmation that the LED
                // is on, which is useful during testing/demos.
                AnimatedBuilder(
                  animation: _torch,
                  builder: (context, _) {
                    if (!_torch.isOn) return const SizedBox.shrink();
                    return Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.flash_on,
                              color: Colors.amber,
                              size: 14,
                            ),
                            SizedBox(width: 4),
                            Text(
                              'TORCH',
                              style: TextStyle(
                                color: Colors.amber,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: _result == null
                ? Center(
                    child: Text(
                      _liveModeOn
                          ? 'Live haptic mode active.\nThe phone will vibrate '
                              'when a recognised object is sustained within '
                              '${_liveDistanceThresholdMeters.toStringAsFixed(1)} '
                              'metres for 2 consecutive frames.\n'
                              'Tap CAPTURE for a full description.'
                          : 'Tap CAPTURE to describe the scene.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 20),
                    ),
                  )
                : ResultList(analysis: _result!),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SosButton(
                  isConfigured: _sosConfigured,
                  onConfirmed: _onSosConfirmed,
                  onSetupNeeded: _openEmergencySetup,
                  size: 84,
                ),
                const SizedBox(width: 12),

                Expanded(
                  child: Semantics(
                    label: 'Capture and describe scene',
                    button: true,
                    child: ElevatedButton.icon(
                      icon: Icon(
                        _busy ? Icons.hourglass_empty : Icons.camera,
                        size: 36,
                      ),
                      label: Text(
                        _busy ? 'ANALYZING...' : 'CAPTURE',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                      ),
                      onPressed: _busy ? null : _capture,
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                Semantics(
                  label: 'Describe scene in detail using Gemini',
                  button: true,
                  child: SizedBox(
                    width: 84,
                    height: 84,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade700,
                        foregroundColor: Colors.white,
                        shape: const CircleBorder(),
                        padding: EdgeInsets.zero,
                      ),
                      onPressed: _describing ? null : _describeWithGemini,
                      child: _describing
                          ? const SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                valueColor:
                                    AlwaysStoppedAnimation(Colors.white),
                              ),
                            )
                          : const Icon(Icons.auto_awesome, size: 36),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}