import 'package:flutter/material.dart';

import '../services/emergency_contacts.dart';
import '../services/sos_service.dart';
import '../services/tts_service.dart';

class EmergencySetupScreen extends StatefulWidget {
  final TtsService tts;
  const EmergencySetupScreen({super.key, required this.tts});

  @override
  State<EmergencySetupScreen> createState() => _EmergencySetupScreenState();
}

class _EmergencySetupScreenState extends State<EmergencySetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone1 = TextEditingController();
  final _phone2 = TextEditingController();
  final _phone3 = TextEditingController();
  final _emailRecipient = TextEditingController();
  final _smtpEmail = TextEditingController();
  final _smtpPassword = TextEditingController();

  bool _loading = true;
  bool _testing = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await EmergencyContactsService.load();
    if (config != null) {
      _name.text = config.userName;
      if (config.phoneNumbers.isNotEmpty) _phone1.text = config.phoneNumbers[0];
      if (config.phoneNumbers.length > 1) _phone2.text = config.phoneNumbers[1];
      if (config.phoneNumbers.length > 2) _phone3.text = config.phoneNumbers[2];
      _emailRecipient.text = config.emailRecipient;
      _smtpEmail.text = config.smtpEmail;
      _smtpPassword.text = config.smtpAppPassword;
    }
    if (mounted) setState(() => _loading = false);
  }

  EmergencyConfig _buildConfig() {
    final phones = [
      _phone1.text.trim(),
      _phone2.text.trim(),
      _phone3.text.trim(),
    ].where((p) => p.isNotEmpty).toList();
    return EmergencyConfig(
      userName: _name.text.trim(),
      phoneNumbers: phones,
      emailRecipient: _emailRecipient.text.trim(),
      smtpEmail: _smtpEmail.text.trim(),
      smtpAppPassword: _smtpPassword.text.trim(),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final config = _buildConfig();
    await EmergencyContactsService.save(config);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Emergency settings saved')),
    );
    await widget.tts.speak('Emergency settings saved.');
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _runTest() async {
    if (!_formKey.currentState!.validate()) return;
    final config = _buildConfig();
    await EmergencyContactsService.save(config);

    setState(() => _testing = true);
    try {
      final sos = SosService(tts: widget.tts);
      final missing = await sos.ensurePermissions();
      if (missing.isNotEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Missing permissions: ${missing.join(", ")}')),
        );
        return;
      }
      final result = await sos.trigger();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(
            'Test result — '
            'SMS ${result.smsSuccessCount}/${result.smsAttemptCount}, '
            'Email ${result.emailSent ? "OK" : "fail"}'
            '${result.emailError != null ? " (${result.emailError})" : ""}',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  String? _phoneValidator(String? v, {bool required = false}) {
    if (v == null || v.trim().isEmpty) {
      return required ? 'Required' : null;
    }
    final cleaned = v.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    if (!RegExp(r'^\+?\d{7,15}$').hasMatch(cleaned)) {
      return 'Use full international format, e.g. +9779812345678';
    }
    return null;
  }

  String? _emailValidator(String? v, {bool required = true}) {
    if (v == null || v.trim().isEmpty) {
      return required ? 'Required' : null;
    }
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+').hasMatch(v.trim())) {
      return 'Invalid email';
    }
    return null;
  }

  @override
  void dispose() {
    _name.dispose();
    _phone1.dispose();
    _phone2.dispose();
    _phone3.dispose();
    _emailRecipient.dispose();
    _smtpEmail.dispose();
    _smtpPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Emergency Setup')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const _SectionLabel('Your name'),
                  TextFormField(
                    controller: _name,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      hintText: 'Used in the emergency message',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Required' : null,
                  ),
                  const SizedBox(height: 24),
                  const _SectionLabel('Emergency phone numbers'),
                  const Text(
                    'At least one. Use international format starting with +.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _phone1,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Primary contact',
                      hintText: '+9779812345678',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) => _phoneValidator(v, required: true),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _phone2,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Secondary (optional)',
                      border: OutlineInputBorder(),
                    ),
                    validator: _phoneValidator,
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _phone3,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Tertiary (optional)',
                      border: OutlineInputBorder(),
                    ),
                    validator: _phoneValidator,
                  ),
                  const SizedBox(height: 24),
                  const _SectionLabel('Emergency email recipient'),
                  TextFormField(
                    controller: _emailRecipient,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      hintText: 'family@example.com',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) => _emailValidator(v),
                  ),
                  const SizedBox(height: 24),
                  const _SectionLabel('Sender Gmail (used to send the email)'),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      border: Border.all(color: Colors.amber.shade200),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'You need a Gmail App Password — NOT your normal Gmail '
                      'password. Steps:\n'
                      '  1. Sign in to https://myaccount.google.com\n'
                      '  2. Security → enable 2-Step Verification\n'
                      '  3. Security → App passwords → create one for "Mail"\n'
                      '  4. Copy the 16-character password and paste it below',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _smtpEmail,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Gmail address',
                      hintText: 'you@gmail.com',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) => _emailValidator(v),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _smtpPassword,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      labelText: 'App Password (16 characters)',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePassword
                            ? Icons.visibility
                            : Icons.visibility_off),
                        onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Required' : null,
                  ),
                  const SizedBox(height: 32),
                  ElevatedButton(
                    onPressed: _save,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: const Text(
                      'SAVE',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _testing ? null : _runTest,
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    label: Text(_testing ? 'Sending...' : 'TEST SEND NOW'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'TEST SEND will save your settings and fire a real SMS '
                    'and email to the contacts above. Use it once to make '
                    'sure everything works.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 24),
                  TextButton(
                    onPressed: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Clear all settings?'),
                          content: const Text(
                              'This removes all phone numbers, emails, and the saved app password.'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Cancel'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Clear',
                                  style: TextStyle(color: Colors.red)),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        await EmergencyContactsService.clear();
                        if (context.mounted) Navigator.pop(context);
                      }
                    },
                    child: const Text('Clear all settings',
                        style: TextStyle(color: Colors.red)),
                  ),
                ],
              ),
            ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
      );
}
