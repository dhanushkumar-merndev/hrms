import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../api/api_client.dart';
import '../api/api_exception.dart';

void showMessage(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? AppColors.error : AppColors.text,
      behavior: SnackBarBehavior.floating,
    ));
}

void showError(BuildContext context, Object error) {
  final msg = error is ApiException ? error.message : 'Something went wrong. Please try again.';
  showMessage(context, msg, error: true);
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: AppColors.error) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Asks for a reason (mandatory unless [optional]). Returns null if cancelled.
Future<String?> askReason(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = 'Submit',
  bool optional = false,
  bool destructive = false,
}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      String? error;
      return StatefulBuilder(builder: (ctx, setState) {
        return AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (message != null) ...[Text(message), const SizedBox(height: AppSpacing.md)],
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 1000,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: optional ? 'Reason (optional)' : 'Reason',
                errorText: error,
              ),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              style: destructive ? FilledButton.styleFrom(backgroundColor: AppColors.error) : null,
              onPressed: () {
                final text = controller.text.trim();
                if (!optional && text.length < 3) {
                  setState(() => error = 'Please give a reason');
                  return;
                }
                Navigator.pop(ctx, text);
              },
              child: Text(confirmLabel),
            ),
          ],
        );
      });
    },
  );
}

/// Password re-entry for sensitive actions. The server verifies the password
/// through Auth and issues a short-lived grant bound to this session+action.
Future<bool> reauthenticate(BuildContext context, WidgetRef ref, {required String action, String? targetId}) async {
  final controller = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      String? error;
      var busy = false;
      return StatefulBuilder(builder: (ctx, setState) {
        Future<void> submit() async {
          setState(() {
            busy = true;
            error = null;
          });
          try {
            await ref.read(apiProvider).function('auth-reauth', {
              'password': controller.text,
              'action': action,
              'target_id': ?targetId,
            });
            if (ctx.mounted) Navigator.pop(ctx, true);
          } on ApiException catch (e) {
            setState(() {
              busy = false;
              error = e.message;
            });
          }
        }

        return AlertDialog(
          title: const Text('Confirm it\'s you'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Enter your password to continue with this sensitive action.'),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(labelText: 'Password', errorText: error),
              onSubmitted: (_) => busy ? null : submit(),
            ),
          ]),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: busy ? null : submit,
              child: busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Confirm'),
            ),
          ],
        );
      });
    },
  );
  return ok ?? false;
}
