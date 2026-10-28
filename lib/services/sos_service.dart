import 'dart:async';

import 'package:another_telephony/telephony.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server/gmail.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';

import 'emergency_contacts.dart';
import 'tts_service.dart';

class SosResult {
  final bool smsAttempted;
  final int smsSuccessCount;
  final int smsAttemptCount;
  final bool emailAttempted;
  final bool emailSent;
  final String? emailError;
  final String? smsError;
  final Position? position;
  final bool locationFromCache;
  final String? configError;

  const SosResult({
    required this.smsAttempted,
    required this.smsSuccessCount,
    required this.smsAttemptCount,
    required this.emailAttempted,
    required this.emailSent,
    this.emailError,
    this.smsError,
    this.position,
    this.locationFromCache = false,
    this.configError,
  });

  bool get anySent => smsSuccessCount > 0 || emailSent;
}

/// Drives the whole emergency flow. Stateful only in that it caches the
/// last known GPS position to avoid the map-link saying "unavailable" if a
/// fresh fix can't be obtained quickly.
class SosService {
  final TtsService tts;
  final Telephony _telephony = Telephony.instance;

  Position? _lastKnownPosition;

  SosService({required this.tts});

  /// Request permissions up front so the SOS itself doesn't get blocked
  /// behind a permission prompt at the worst possible moment. Call this
  /// once on app start (after first frame) and again when the user opens
  /// emergency setup.
  Future<List<String>> ensurePermissions() async {
    final missing = <String>[];

    final loc = await Permission.location.request();
    if (!loc.isGranted) missing.add('Location');

    final sms = await Permission.sms.request();
    if (!sms.isGranted) missing.add('SMS');

    return missing;
  }

  // ---------------------------------------------------------------------------
  // Location
  // ---------------------------------------------------------------------------

  /// Best-effort GPS. Tight 8-second timeout; falls back to last known fix.
  /// Never blocks the SOS for more than ~8s.
  Future<({Position? position, bool fromCache})> _getPosition() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        // try one request — user may have granted via the up-front prompt
        final retry = await Geolocator.requestPermission();
        if (retry == LocationPermission.denied ||
            retry == LocationPermission.deniedForever) {
          return (
            position: _lastKnownPosition,
            fromCache: _lastKnownPosition != null,
          );
        }
      }

      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return (
          position: _lastKnownPosition,
          fromCache: _lastKnownPosition != null,
        );
      }

      try {
        final fresh = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 8),
          ),
        );
        _lastKnownPosition = fresh;
        return (position: fresh, fromCache: false);
      } on TimeoutException {
        final cached = await Geolocator.getLastKnownPosition() ??
            _lastKnownPosition;
        if (cached != null) _lastKnownPosition = cached;
        return (position: cached, fromCache: true);
      }
    } catch (_) {
      return (
        position: _lastKnownPosition,
        fromCache: _lastKnownPosition != null,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Message construction
  // ---------------------------------------------------------------------------

  String _buildBody(EmergencyConfig config, Position? position,
      {required bool cachedLocation}) {
    final now = DateTime.now();
    final timeStr =
        '${now.year}-${_pad(now.month)}-${_pad(now.day)} ${_pad(now.hour)}:${_pad(now.minute)}';

    final name = config.userName.isEmpty ? 'A user' : config.userName;

    String locationLine;
    if (position != null) {
      final lat = position.latitude.toStringAsFixed(6);
      final lng = position.longitude.toStringAsFixed(6);
      final cached = cachedLocation ? ' (last known)' : '';
      locationLine =
          'Location$cached: https://maps.google.com/?q=$lat,$lng';
    } else {
      locationLine = 'Location: unavailable';
    }

    return 'EMERGENCY. $name needs help.\n$locationLine\nTime: $timeStr';
  }

  String _pad(int v) => v.toString().padLeft(2, '0');

  // ---------------------------------------------------------------------------
  // SMS
  // ---------------------------------------------------------------------------

  /// Sends a single SMS. The sendSms call returns once the message is queued
  /// to the radio. We treat that as success — actual DELIVERED status is
  /// flaky on some carriers and we'd rather ship the SOS than wait.
  Future<bool> _sendOneSms(String number, String body) async {
    try {
      await _telephony.sendSms(
        to: number,
        message: body,
        isMultipart: true, // long bodies get split
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Email
  // ---------------------------------------------------------------------------

  Future<({bool ok, String? error})> _sendEmail(
    EmergencyConfig config,
    String body,
    Position? position,
  ) async {
    if (!config.emailConfigured) {
      return (ok: false, error: 'Email not configured');
    }

    try {
      final smtp = gmail(config.smtpEmail, config.smtpAppPassword);
      final senderName = config.userName.isEmpty
          ? 'Visual Assist Emergency'
          : '${config.userName} (Emergency)';

      final message = Message()
        ..from = Address(config.smtpEmail, senderName)
        ..recipients.add(config.emailRecipient)
        ..subject =
            'EMERGENCY: ${config.userName.isEmpty ? "Visual Assist user" : config.userName} needs help'
        ..text = body
        ..html = _emailHtml(config, body, position);

      await send(message, smtp).timeout(const Duration(seconds: 15));
      return (ok: true, error: null);
    } on MailerException catch (e) {
      return (
        ok: false,
        error: e.message.isEmpty ? 'Mailer error' : e.message,
      );
    } on TimeoutException {
      return (ok: false, error: 'Email send timed out');
    } catch (e) {
      return (ok: false, error: e.toString());
    }
  }

  String _emailHtml(
      EmergencyConfig config, String body, Position? position) {
    final mapsUrl = position != null
        ? 'https://maps.google.com/?q=${position.latitude},${position.longitude}'
        : null;
    final name = config.userName.isEmpty ? 'A Visual Assist user' : config.userName;

    return '''
<!doctype html>
<html><body style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;">
  <h2 style="color:#b00020;margin:0 0 8px;">⚠ EMERGENCY</h2>
  <p style="font-size:16px;"><strong>$name</strong> has triggered an emergency SOS from Visual Assist.</p>
  <pre style="background:#f4f4f4;padding:12px;border-radius:6px;white-space:pre-wrap;">$body</pre>
  ${mapsUrl != null ? '<p><a href="$mapsUrl" style="display:inline-block;padding:10px 16px;background:#1a73e8;color:#fff;border-radius:6px;text-decoration:none;">Open location in Google Maps</a></p>' : '<p><em>Live location unavailable.</em></p>'}
  <hr style="margin:24px 0;border:none;border-top:1px solid #ddd;">
  <p style="color:#888;font-size:12px;">Sent automatically by Visual Assist on the user's phone.</p>
</body></html>
''';
  }

  // ---------------------------------------------------------------------------
  // Haptics
  // ---------------------------------------------------------------------------

  Future<void> _vibrateSosPattern() async {
    // vibration ^2.1.0+ returns a non-nullable bool.
    final has = await Vibration.hasVibrator();
    if (!has) return;
    // Morse SOS: ... --- ...
    Vibration.vibrate(pattern: [
      0, 200, 100, 200, 100, 200,
      300, 600, 100, 600, 100, 600,
      300, 200, 100, 200, 100, 200,
    ]);
  }

  Future<void> _vibrateConfirm() async {
    final has = await Vibration.hasVibrator();
    if (!has) return;
    Vibration.vibrate(pattern: [0, 80, 80, 80, 80, 200]);
  }

  // ---------------------------------------------------------------------------
  // Public entry point
  // ---------------------------------------------------------------------------

  /// Run the full SOS flow. Speaks status updates throughout so the user
  /// knows what's happening even though they can't see the screen.
  Future<SosResult> trigger() async {
    // Immediate audible+haptic acknowledgement so the user knows the button
    // registered, even before we've done anything useful.
    unawaited(_vibrateSosPattern());
    await tts.speak('Sending emergency message');

    final config = await EmergencyContactsService.load();
    if (config == null || !config.isUsable) {
      await tts.speak(
        'Emergency contacts are not set up. Open settings to configure.',
      );
      return const SosResult(
        smsAttempted: false,
        smsSuccessCount: 0,
        smsAttemptCount: 0,
        emailAttempted: false,
        emailSent: false,
        configError: 'No usable config',
      );
    }

    final locResult = await _getPosition();
    final body = _buildBody(
      config,
      locResult.position,
      cachedLocation: locResult.fromCache,
    );

    // Fire SMS in parallel with email so a slow SMTP doesn't delay texts.
    final smsFuture = config.smsConfigured
        ? Future.wait(
            config.phoneNumbers.map((n) => _sendOneSms(n, body)),
          )
        : Future.value(<bool>[]);

    final emailFuture = config.emailConfigured
        ? _sendEmail(config, body, locResult.position)
        : Future.value((ok: false, error: 'not configured'));

    final results = await Future.wait([smsFuture, emailFuture]);
    final smsResults = results[0] as List<bool>;
    final emailResult =
        results[1] as ({bool ok, String? error});

    final smsOk = smsResults.where((r) => r).length;
    final smsTotal = smsResults.length;

    // Speak result summary — keep it short.
    final spoken = StringBuffer();
    if (config.smsConfigured) {
      if (smsOk == smsTotal && smsTotal > 0) {
        spoken.write(
            'Text message sent to $smsOk ${smsOk == 1 ? "contact" : "contacts"}. ');
      } else if (smsOk > 0) {
        spoken.write('Text sent to $smsOk of $smsTotal contacts. ');
      } else {
        spoken.write('Text message failed. ');
      }
    }
    if (config.emailConfigured) {
      if (emailResult.ok) {
        spoken.write('Email sent.');
      } else {
        spoken.write('Email failed.');
      }
    }
    if (locResult.position == null) {
      spoken.write(' Warning, location was not available.');
    } else if (locResult.fromCache) {
      spoken.write(' Location is from last known fix.');
    }
    await tts.speak(spoken.toString().trim());

    if (smsOk > 0 || emailResult.ok) {
      unawaited(_vibrateConfirm());
    }

    return SosResult(
      smsAttempted: config.smsConfigured,
      smsSuccessCount: smsOk,
      smsAttemptCount: smsTotal,
      emailAttempted: config.emailConfigured,
      emailSent: emailResult.ok,
      emailError: emailResult.error,
      smsError: smsOk == 0 && smsTotal > 0 ? 'All SMS sends failed' : null,
      position: locResult.position,
      locationFromCache: locResult.fromCache,
    );
  }
}
