import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A big red round SOS button that requires a 2-second hold to fire.
///
/// Why hold-to-fire instead of a tap or triple-tap:
/// - A blind user touching the screen to find buttons must not accidentally
///   trigger an emergency.
/// - 2s is long enough to filter accidents but short enough that a real
///   emergency doesn't feel sluggish.
/// - The progress ring + escalating vibration give an unambiguous "you are
///   firing the SOS" cue that doesn't require sight.
class SosButton extends StatefulWidget {
  final Future<void> Function() onConfirmed;
  final VoidCallback? onSetupNeeded;
  final bool isConfigured;
  final double size;

  const SosButton({
    super.key,
    required this.onConfirmed,
    required this.isConfigured,
    this.onSetupNeeded,
    this.size = 96,
  });

  @override
  State<SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends State<SosButton>
    with SingleTickerProviderStateMixin {
  static const _holdDuration = Duration(milliseconds: 2000);

  late final AnimationController _holdController;
  bool _firing = false;
  bool _holding = false;

  @override
  void initState() {
    super.initState();
    _holdController = AnimationController(
      vsync: this,
      duration: _holdDuration,
    );
    _holdController.addStatusListener(_onStatus);
    // Pulse vibration ticks at 25 / 50 / 75% to give the user a "charging" cue
    _holdController.addListener(_maybeTick);
  }

  double _lastTick = 0;
  void _maybeTick() {
    final v = _holdController.value;
    if (v - _lastTick > 0.25 && _holding) {
      _lastTick = v;
      HapticFeedback.lightImpact();
    }
  }

  Future<void> _onStatus(AnimationStatus status) async {
    if (status == AnimationStatus.completed && !_firing && _holding) {
      _firing = true;
      HapticFeedback.heavyImpact();
      try {
        await widget.onConfirmed();
      } finally {
        if (mounted) {
          _holdController.reset();
          _lastTick = 0;
          _firing = false;
          _holding = false;
        }
      }
    }
  }

  @override
  void dispose() {
    _holdController.removeListener(_maybeTick);
    _holdController.removeStatusListener(_onStatus);
    _holdController.dispose();
    super.dispose();
  }

  void _start() {
    if (_firing) return;
    if (!widget.isConfigured) {
      HapticFeedback.mediumImpact();
      widget.onSetupNeeded?.call();
      return;
    }
    _holding = true;
    _lastTick = 0;
    HapticFeedback.mediumImpact();
    _holdController.forward();
  }

  void _cancel() {
    _holding = false;
    if (!_firing) {
      _holdController.reverse();
      _lastTick = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.isConfigured
        ? 'SOS. Press and hold for two seconds to send an emergency message.'
        : 'SOS, not configured. Activate to open emergency setup.';

    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _start(),
        onTapUp: (_) => _cancel(),
        onTapCancel: _cancel,
        onLongPressStart: (_) => _start(),
        onLongPressEnd: (_) => _cancel(),
        onLongPressCancel: _cancel,
        child: AnimatedBuilder(
          animation: _holdController,
          builder: (context, _) {
            final v = _holdController.value;
            return SizedBox(
              width: widget.size,
              height: widget.size,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Glow halo
                  Container(
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.red.shade700,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.red.withValues(alpha: 0.4 + 0.4 * v),
                          blurRadius: 18 + 30 * v,
                          spreadRadius: 2 + 6 * v,
                        ),
                      ],
                      border: Border.all(color: Colors.white, width: 4),
                    ),
                  ),
                  // Progress ring while holding
                  if (v > 0.01)
                    SizedBox(
                      width: widget.size - 4,
                      height: widget.size - 4,
                      child: CircularProgressIndicator(
                        value: v,
                        strokeWidth: 6,
                        backgroundColor: Colors.transparent,
                        valueColor:
                            const AlwaysStoppedAnimation(Colors.white),
                      ),
                    ),
                  Text(
                    'SOS',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: widget.size * 0.30,
                      letterSpacing: 2,
                      shadows: const [
                        Shadow(
                          color: Colors.black54,
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
