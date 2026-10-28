import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

/// Manages the device torch (flashlight) via the camera controller.
///
/// Why a separate service:
///   * Centralizes torch state so multiple widgets can read/toggle it.
///   * Keeps `setFlashMode` calls behind a try/catch — some devices
///     (notably OnePlus / ColorOS) throw if you call setFlashMode
///     before the camera is fully initialized, and we'd rather log
///     and continue than crash the app.
///   * Provides a single "is torch supported?" check so the UI can
///     hide the button on front cameras (which have no flash).
///
/// Usage:
///   final torch = TorchService();
///   torch.attach(cameraController);     // call after camera init
///   await torch.toggle();               // bind to a button
///   torch.isOn                          // for UI state
///   torch.detach();                     // call before disposing camera
class TorchService extends ChangeNotifier {
  CameraController? _controller;
  bool _isOn = false;
  bool _supported = false;

  bool get isOn => _isOn;
  bool get isSupported => _supported;

  /// Attach to a freshly-initialized camera controller. Safe to call
  /// multiple times; each call replaces the previous binding.
  void attach(CameraController controller) {
    _controller = controller;
    // Front cameras typically have no torch hardware. We can't reliably
    // query the camera plugin for "has flash", so we use the lens
    // direction as a proxy and let the actual setFlashMode call fail
    // gracefully on devices that surprise us.
    _supported =
        controller.description.lensDirection == CameraLensDirection.back;
    _isOn = false;
    notifyListeners();
  }

  /// Detach before disposing the camera controller, so we don't hold
  /// a dead reference.
  void detach() {
    _controller = null;
    _isOn = false;
    _supported = false;
    notifyListeners();
  }

  /// Toggle the torch. Returns the new on/off state, or `null` if the
  /// operation failed (e.g. controller not initialized, no flash).
  Future<bool?> toggle() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      // ignore: avoid_print
      print('[TorchService] toggle ignored: controller not ready');
      return null;
    }
    if (!_supported) {
      // ignore: avoid_print
      print('[TorchService] toggle ignored: torch not supported on this lens');
      return null;
    }

    final target = _isOn ? FlashMode.off : FlashMode.torch;
    try {
      await c.setFlashMode(target);
      _isOn = !_isOn;
      // ignore: avoid_print
      print('[TorchService] torch ${_isOn ? "ON" : "OFF"}');
      notifyListeners();
      return _isOn;
    } catch (e) {
      // ignore: avoid_print
      print('[TorchService] setFlashMode failed: $e');
      return null;
    }
  }

  /// Force the torch off — call this when the app goes to background,
  /// when entering capture/live mode if it interferes, or before
  /// disposing the camera.
  Future<void> forceOff() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    try {
      await c.setFlashMode(FlashMode.off);
    } catch (_) {/* swallow */}
    if (_isOn) {
      _isOn = false;
      notifyListeners();
    }
  }
}