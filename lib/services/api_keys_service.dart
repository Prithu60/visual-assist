import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores the Gemini API key in encrypted storage.
///
/// We don't ship the key in code — the user (or family) enters it in settings.
/// That way the same APK can be shared between users, and the key isn't
/// vulnerable to reverse engineering.
class ApiKeysService {
  static const _geminiKey = 'gemini_api_key_v1';

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static Future<String> readGeminiKey() async {
    return await _storage.read(key: _geminiKey) ?? '';
  }

  static Future<void> writeGeminiKey(String value) async {
    await _storage.write(key: _geminiKey, value: value.trim());
  }

  static Future<void> clearGeminiKey() async {
    await _storage.delete(key: _geminiKey);
  }
}
