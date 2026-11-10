import 'package:flutter/material.dart';

import '../services/password_prompt.dart';
import '../services/settings_store.dart';

/// Shown only on the very first launch after install. Until the user
/// types [kMasterResetCode] the rest of the app is unreachable, so an
/// APK that lands on someone else's phone can't be opened.
///
/// The activation flag is stored in SharedPreferences — wiping app data
/// (or uninstall+reinstall) brings the gate back, by design.
class ActivationScreen extends StatefulWidget {
  final AppSettings settings;
  final VoidCallback onActivated;
  const ActivationScreen({
    super.key,
    required this.settings,
    required this.onActivated,
  });

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final TextEditingController _ctrl = TextEditingController();
  bool _obscure = true;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final entered = _ctrl.text.trim();
    if (entered != kMasterResetCode) {
      setState(() => _error = 'Wrong activation code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await widget.settings.setActivated(true);
    if (!mounted) return;
    widget.onActivated();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 72, color: scheme.primary),
                const SizedBox(height: 16),
                const Text(
                  'Print Collage Tool',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Enter the activation code to unlock this install.',
                  style: TextStyle(fontSize: 14),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _ctrl,
                  autofocus: true,
                  obscureText: _obscure,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: 'Activation code',
                    errorText: _error,
                    suffixIcon: IconButton(
                      icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Text('Unlock'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
