import 'package:flutter/material.dart';

/// Fixed master reset code. Anyone who knows this can bypass any password
/// gate in the app — used as the recovery escape hatch. Deliberately NOT
/// shown in any UI text; the user (and people they tell) must just know it.
const String kMasterResetCode = '7050';

/// Shows a modal password dialog and returns `true` if the user typed the
/// expected password OR the master reset code, `false` on cancel.
///
/// Wrong attempts keep the dialog open with an inline error rather than
/// dismissing — the user has to either get it right or tap Cancel.
Future<bool?> promptForPassword({
  required BuildContext context,
  required String expected,
  required String title,
  required String description,
  String continueLabel = 'Continue',
}) {
  final ctrl = TextEditingController();
  var obscure = true;
  String? error;
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        icon: const Icon(Icons.lock_outline),
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(description, style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              obscureText: obscure,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: 'Password',
                errorText: error,
                suffixIcon: IconButton(
                  icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setLocal(() => obscure = !obscure),
                ),
              ),
              onSubmitted: (_) {
                if (ctrl.text == expected || ctrl.text == kMasterResetCode) {
                  Navigator.of(ctx).pop(true);
                } else {
                  setLocal(() => error = 'Wrong password');
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (ctrl.text == expected || ctrl.text == kMasterResetCode) {
                Navigator.of(ctx).pop(true);
              } else {
                setLocal(() => error = 'Wrong password');
              }
            },
            child: Text(continueLabel),
          ),
        ],
      ),
    ),
  );
}

/// Two-field dialog for setting a new password. Returns the entered password
/// (which may be empty meaning "remove the password") or null on cancel.
Future<String?> promptForNewPassword({
  required BuildContext context,
  required String title,
}) {
  final newCtrl = TextEditingController();
  final confirmCtrl = TextEditingController();
  var obscure = true;
  String? error;
  return showDialog<String?>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        icon: const Icon(Icons.lock_reset),
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Leave blank to remove the password entirely.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: newCtrl,
              autofocus: true,
              obscureText: obscure,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: 'New password',
                suffixIcon: IconButton(
                  icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setLocal(() => obscure = !obscure),
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: confirmCtrl,
              obscureText: obscure,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: 'Confirm new password',
                errorText: error,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (newCtrl.text != confirmCtrl.text) {
                setLocal(() => error = 'Passwords do not match');
                return;
              }
              Navigator.of(ctx).pop(newCtrl.text);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}
