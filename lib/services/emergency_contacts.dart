import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds everything the SOS feature needs.
///
/// Plain fields (name / phones / recipient email) live in shared_preferences.
/// Sensitive credentials (Gmail SMTP App Password) live in flutter_secure_storage.
class EmergencyConfig {
  final String userName;
  final List<String> phoneNumbers; // 1–3 numbers
  final String emailRecipient;

  // Gmail SMTP credentials used to SEND the email
  final String smtpEmail;
  final String smtpAppPassword; // 16-char Gmail App Password

  const EmergencyConfig({
    required this.userName,
    required this.phoneNumbers,
    required this.emailRecipient,
    required this.smtpEmail,
    required this.smtpAppPassword,
  });

  EmergencyConfig copyWith({
    String? userName,
    List<String>? phoneNumbers,
    String? emailRecipient,
    String? smtpEmail,
    String? smtpAppPassword,
  }) =>
      EmergencyConfig(
        userName: userName ?? this.userName,
        phoneNumbers: phoneNumbers ?? this.phoneNumbers,
        emailRecipient: emailRecipient ?? this.emailRecipient,
        smtpEmail: smtpEmail ?? this.smtpEmail,
        smtpAppPassword: smtpAppPassword ?? this.smtpAppPassword,
      );

  Map<String, dynamic> _publicJson() => {
        'userName': userName,
        'phoneNumbers': phoneNumbers,
        'emailRecipient': emailRecipient,
        'smtpEmail': smtpEmail, // safe to keep in prefs
      };

  factory EmergencyConfig._fromPublicJson(
    Map<String, dynamic> json, {
    required String smtpAppPassword,
  }) =>
      EmergencyConfig(
        userName: (json['userName'] ?? '') as String,
        phoneNumbers: List<String>.from(json['phoneNumbers'] ?? const []),
        emailRecipient: (json['emailRecipient'] ?? '') as String,
        smtpEmail: (json['smtpEmail'] ?? '') as String,
        smtpAppPassword: smtpAppPassword,
      );

  /// Whether this config has the bare minimum to fire an SOS.
  ///
  /// SMS path: name + at least one phone.
  /// Email path: recipient + sender Gmail + app password.
  /// Either path being usable is enough.
  bool get isUsable {
    final smsOk = userName.isNotEmpty && phoneNumbers.isNotEmpty;
    final emailOk = emailRecipient.isNotEmpty &&
        smtpEmail.isNotEmpty &&
        smtpAppPassword.isNotEmpty;
    return smsOk || emailOk;
  }

  bool get smsConfigured => phoneNumbers.isNotEmpty;
  bool get emailConfigured =>
      emailRecipient.isNotEmpty &&
      smtpEmail.isNotEmpty &&
      smtpAppPassword.isNotEmpty;
}

class EmergencyContactsService {
  static const _prefsKey = 'emergency_config_v1';
  static const _smtpPasswordKey = 'smtp_app_password_v1';

  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static Future<EmergencyConfig?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return null;

    final smtpPassword =
        await _secureStorage.read(key: _smtpPasswordKey) ?? '';

    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return EmergencyConfig._fromPublicJson(
        json,
        smtpAppPassword: smtpPassword,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(EmergencyConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(config._publicJson()));
    await _secureStorage.write(
      key: _smtpPasswordKey,
      value: config.smtpAppPassword,
    );
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    await _secureStorage.delete(key: _smtpPasswordKey);
  }
}
