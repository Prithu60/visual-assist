import 'package:flutter/material.dart';

import '../services/api_keys_service.dart';
import '../services/tts_service.dart';

class GeminiSettingsScreen extends StatefulWidget {
  final TtsService tts;
  const GeminiSettingsScreen({super.key, required this.tts});

  @override
  State<GeminiSettingsScreen> createState() => _GeminiSettingsScreenState();
}

class _GeminiSettingsScreenState extends State<GeminiSettingsScreen> {
  final _ctrl = TextEditingController();
  bool _loading = true;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _ctrl.text = await ApiKeysService.readGeminiKey();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final key = _ctrl.text.trim();
    if (key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter an API key first.')),
      );
      return;
    }
    await ApiKeysService.writeGeminiKey(key);
    if (!mounted) return;
    await widget.tts.speak('Gemini key saved.');
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gemini API Key')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    border: Border.all(color: Colors.blue.shade200),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'How to get a Gemini API key:\n'
                    '  1. Go to aistudio.google.com\n'
                    '  2. Sign in with a Google account\n'
                    '  3. Click "Get API key" → "Create API key"\n'
                    '  4. Copy the key and paste it here\n'
                    '\n'
                    'A free tier exists but has rate limits. The key is '
                    'stored encrypted on this phone — never sent anywhere '
                    'except google.com.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _ctrl,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: 'Gemini API key',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure
                          ? Icons.visibility
                          : Icons.visibility_off),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _save,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('SAVE',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () async {
                    await ApiKeysService.clearGeminiKey();
                    _ctrl.clear();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Key cleared')),
                      );
                    }
                  },
                  child: const Text('Clear key',
                      style: TextStyle(color: Colors.red)),
                ),
              ],
            ),
    );
  }
}
