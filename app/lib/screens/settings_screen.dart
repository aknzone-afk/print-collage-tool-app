import 'package:flutter/material.dart';

import '../config.dart';
import '../services/design_library.dart';
import '../services/onedrive_auth.dart' show OneDriveAuth, DeviceCodeChallenge;
import '../services/onedrive_client.dart';
import '../services/password_prompt.dart';
import '../services/settings_store.dart';

class SettingsScreen extends StatefulWidget {
  final AppSettings settings;
  final DesignLibrary designLibrary;
  const SettingsScreen({super.key, required this.settings, required this.designLibrary});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _emailCtrl;
  late final TextEditingController _folderCtrl;
  late bool _roundUp;
  final OneDriveAuth _auth = OneDriveAuth();
  bool _signedIn = false;
  String? _signedInAs;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _emailCtrl = TextEditingController(text: widget.settings.destinationEmail);
    _folderCtrl = TextEditingController(text: widget.settings.oneDriveFolder);
    _roundUp = widget.settings.roundUpExtras;
    _checkSignIn();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _folderCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkSignIn() async {
    final signed = await _auth.isSignedIn;
    if (!mounted) return;
    setState(() => _signedIn = signed);
    if (signed) {
      try {
        final profile = await OneDriveClient(_auth).getMyProfile();
        if (mounted) {
          setState(() => _signedInAs = profile['userPrincipalName'] as String? ?? profile['mail'] as String?);
        }
      } catch (_) {}
    }
  }

  Future<void> _signIn() async {
    if (!AzureConfig.isConfigured) {
      _showSetupHelp();
      return;
    }
    setState(() => _busy = true);
    try {
      final challenge = await _auth.startDeviceCodeSignIn();
      if (!mounted) return;
      // Show dialog with code + URL while polling in background
      final dialogFuture = _showDeviceCodeDialog(challenge);
      final pollFuture = _auth.completeDeviceCodeSignIn();
      final result = await Future.any<Object?>([
        pollFuture.then((token) => token),
        dialogFuture.then((cancelled) => cancelled == true ? Exception('cancelled') : null),
      ]);
      if (mounted) Navigator.of(context, rootNavigator: true).maybePop();
      if (result is Exception) {
        await _auth.cancelDeviceCodeSignIn();
        return;
      }
      await _checkSignIn();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Signed in to Microsoft')),
        );
      }
    } catch (e) {
      await _auth.cancelDeviceCodeSignIn();
      if (mounted) {
        Navigator.of(context, rootNavigator: true).maybePop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sign-in failed: $e'), duration: const Duration(seconds: 6)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _showDeviceCodeDialog(DeviceCodeChallenge challenge) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign in on a computer'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'On any computer or phone browser, open this URL:',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              SelectableText(
                challenge.verificationUri,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 16),
              const Text('Then enter this code:', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  challenge.userCode,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 4,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: const [
                  SizedBox(
                      width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Expanded(child: Text('Waiting for sign-in…', style: TextStyle(fontSize: 13))),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Sign in with the Microsoft account whose OneDrive has your design files.',
                style: TextStyle(fontSize: 11, color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _signOut() async {
    await _auth.signOut();
    widget.designLibrary.invalidate();
    if (mounted) {
      setState(() {
        _signedIn = false;
        _signedInAs = null;
      });
    }
  }

  Future<void> _save() async {
    final oldFolder = widget.settings.oneDriveFolder;
    await widget.settings.setDestinationEmail(_emailCtrl.text);
    await widget.settings.setOneDriveFolder(_folderCtrl.text);
    await widget.settings.setRoundUpExtras(_roundUp);
    // Note: send password is managed via the dedicated dialog flow, not from
    // this Save button — keeps the password from being visible in a TextField.
    if (oldFolder != _folderCtrl.text.trim()) {
      widget.designLibrary.invalidate();
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
    }
  }

  /// Generic set / change / remove flow for one of the app's password
  /// settings. If [currentValue] is non-empty, the user must verify it (or
  /// type the master reset code) before being shown the new-password fields.
  Future<void> _managePasswordFlow({
    required String label,
    required String currentValue,
    required Future<void> Function(String) save,
  }) async {
    if (currentValue.isNotEmpty) {
      final ok = await promptForPassword(
        context: context,
        expected: currentValue,
        title: 'Enter current $label password',
        description:
            'Type your current $label password to change or remove it.',
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    final result = await promptForNewPassword(
      context: context,
      title: 'Set new $label password',
    );
    if (result == null) return; // cancelled
    await save(result);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(
        result.isEmpty ? '$label password removed' : '$label password updated',
      )),
    );
  }

  Future<void> _manageSendPassword() => _managePasswordFlow(
        label: 'send',
        currentValue: widget.settings.sendPassword,
        save: widget.settings.setSendPassword,
      );

  Future<void> _manageSettingsPassword() => _managePasswordFlow(
        label: 'settings',
        currentValue: widget.settings.settingsPassword,
        save: widget.settings.setSettingsPassword,
      );

  void _showSetupHelp() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('OneDrive setup needed'),
        content: const SingleChildScrollView(
          child: Text(
            'This app needs a one-time Microsoft account setup:\n\n'
            '1. Open portal.azure.com on a computer\n'
            '2. Search "App registrations" → New registration\n'
            '3. Name: Print Collage Tool\n'
            '4. Account types: Personal Microsoft accounts only\n'
            '5. Redirect URI: tick the pre-listed\n'
            '   "msal<clientid>://auth (MSAL only)" checkbox\n'
            '6. After registering, copy the "Application (client) ID"\n'
            '7. Send it to your developer (or paste it in lib/config.dart)\n\n'
            'Then API permissions → Microsoft Graph delegated:\n'
            '  • Files.Read\n'
            '  • Mail.Send\n'
            '  • User.Read\n'
            '  • offline_access',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionTitle('OneDrive'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(_signedIn ? Icons.check_circle : Icons.cloud_off,
                          color: _signedIn ? Colors.green : Colors.grey),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _signedIn
                              ? (_signedInAs == null ? 'Signed in' : 'Signed in as $_signedInAs')
                              : 'Not signed in',
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                      if (_busy)
                        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (!AzureConfig.isConfigured)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        border: Border.all(color: Colors.orange.shade300),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber, color: Colors.orange),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text('One-time Microsoft Azure setup needed before sign-in works.'),
                          ),
                          TextButton(onPressed: _showSetupHelp, child: const Text('How')),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (!_signedIn)
                        FilledButton.icon(
                          icon: const Icon(Icons.login),
                          onPressed: _busy ? null : _signIn,
                          label: const Text('Sign in to Microsoft'),
                        )
                      else
                        OutlinedButton.icon(
                          icon: const Icon(Icons.logout),
                          onPressed: _signOut,
                          label: const Text('Sign out'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const _SectionTitle('OneDrive folder'),
          TextField(
            controller: _folderCtrl,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Designs folder',
              hintText: 'e.g. 12 X 18',
              helperText: 'Folder must contain your design images named like 1444.jpg, 1333A.jpg',
            ),
          ),
          const SizedBox(height: 24),
          const _SectionTitle('Send print order to'),
          TextField(
            controller: _emailCtrl,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Destination email',
              hintText: 'shop@example.com',
            ),
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: 12),
          _PasswordRow(
            title: 'Send password',
            descriptionWhenSet: 'Required before opening the email app.',
            descriptionWhenUnset:
                'Anyone with the phone can send a print order.',
            isSet: widget.settings.sendPassword.isNotEmpty,
            onManage: _manageSendPassword,
          ),
          const SizedBox(height: 24),
          const _SectionTitle('Settings password'),
          _PasswordRow(
            title: 'Settings password',
            descriptionWhenSet:
                'Required before opening the Settings screen.',
            descriptionWhenUnset:
                'Anyone with the phone can change app settings.',
            isSet: widget.settings.settingsPassword.isNotEmpty,
            onManage: _manageSettingsPassword,
          ),
          const SizedBox(height: 24),
          const _SectionTitle('Print options'),
          SwitchListTile(
            title: const Text('Round up extras'),
            subtitle: const Text('Fill empty slots with extras of highest-quantity design (recommended)'),
            value: _roundUp,
            onChanged: (v) => setState(() => _roundUp = v),
          ),
          const SizedBox(height: 32),
          FilledButton(
            onPressed: _save,
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text('Save Settings'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.1,
              color: Theme.of(context).colorScheme.primary,
            )),
      );
}

/// Status card for one of the app's password gates. Never shows the stored
/// password — just whether one is set, plus a button that opens the
/// verify-then-change dialog flow.
class _PasswordRow extends StatelessWidget {
  final String title;
  final String descriptionWhenSet;
  final String descriptionWhenUnset;
  final bool isSet;
  final VoidCallback onManage;
  const _PasswordRow({
    required this.title,
    required this.descriptionWhenSet,
    required this.descriptionWhenUnset,
    required this.isSet,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Icon(
              isSet ? Icons.lock : Icons.lock_open_outlined,
              color: isSet ? Colors.green.shade700 : scheme.outline,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isSet ? '$title is set' : 'No $title',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isSet ? descriptionWhenSet : descriptionWhenUnset,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: onManage,
              child: Text(isSet ? 'Change' : 'Set'),
            ),
          ],
        ),
      ),
    );
  }
}
