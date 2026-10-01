import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/api/api_exception.dart';
import '../../core/auth/session_controller.dart';
import '../../core/widgets/app_icon.dart';

/// S02 — mandatory first password change / self-service change, and the
/// restricted recovery view while a credential operation is pending.
/// Business navigation is unavailable here.
class PasswordChangeScreen extends ConsumerStatefulWidget {
  const PasswordChangeScreen({super.key, this.voluntary = false});
  final bool voluntary;

  @override
  ConsumerState<PasswordChangeScreen> createState() => _PasswordChangeScreenState();
}

class _PasswordChangeScreenState extends ConsumerState<PasswordChangeScreen> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  bool _obscure = true;
  String? _error;
  Map<String, String> _fieldErrors = const {};

  @override
  void initState() {
    super.initState();
    _next.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _error = null;
      _fieldErrors = const {};
    });
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    try {
      await ref.read(sessionProvider.notifier).changePassword(_current.text, _next.text);
      if (mounted && widget.voluntary && Navigator.of(context).canPop()) Navigator.of(context).pop();
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _fieldErrors = e.fieldErrors;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sessionProvider);
    final hold = state.phase == SessionPhase.credentialHold;
    final ctx = state.context;
    final pw = _next.text;
    final rules = [
      ('At least 12 characters', pw.length >= 12),
      ('Does not contain your employee ID', ctx == null || !pw.toUpperCase().contains(ctx.code)),
      ('Different from your current password', pw.isNotEmpty && pw != _current.text),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.voluntary ? 'Change password' : 'Set a new password'),
        automaticallyImplyLeading: widget.voluntary,
        actions: [
          if (!widget.voluntary)
            TextButton(onPressed: () => ref.read(sessionProvider.notifier).logout(), child: const Text('Sign out')),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Form(
            key: _form,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (hold)
                const _Note('A password change for your account is still being completed. Enter the same details '
                    'again to finish it safely.')
              else if (!widget.voluntary)
                _Note('Hi ${ctx?.firstName ?? ''}. For security, set your own password before continuing.'),
              const SizedBox(height: AppSpacing.xl),
              TextFormField(
                controller: _current,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                decoration: InputDecoration(
                  labelText: widget.voluntary ? 'Current password' : 'Temporary or current password',
                  errorText: _fieldErrors['current_password'],
                ),
                validator: (v) => (v ?? '').isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: AppSpacing.lg),
              TextFormField(
                controller: _next,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                autofillHints: const [AutofillHints.newPassword],
                decoration: InputDecoration(labelText: 'New password', errorText: _fieldErrors['new_password']),
                validator: (v) => rules.every((r) => r.$2) ? null : 'Meet all the rules below',
              ),
              const SizedBox(height: AppSpacing.lg),
              TextFormField(
                controller: _confirm,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                decoration: const InputDecoration(labelText: 'Confirm new password'),
                validator: (v) => v != _next.text ? 'Passwords do not match' : null,
              ),
              CheckboxListTile(
                value: !_obscure,
                onChanged: (v) => setState(() => _obscure = !(v ?? false)),
                title: const Text('Show passwords'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: AppSpacing.sm),
              for (final r in rules)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    AppIcon(r.$2 ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                        size: 20, color: r.$2 ? AppColors.success : AppColors.textSecondary),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(child: Text(r.$1, style: Theme.of(context).textTheme.bodyMedium)),
                  ]),
                ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.lg),
                Semantics(
                  liveRegion: true,
                  child: Text(_error!, style: const TextStyle(color: AppColors.error, fontSize: 15)),
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                    : const Text('Save password'),
              ),
              const SizedBox(height: AppSpacing.md),
              Text('After saving, you will be signed in again with your new password on this phone. '
                  'Other signed-in phones will be signed out.',
                  style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(color: AppColors.attendanceCard, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        const AppIcon(Icons.shield_outlined, color: AppColors.primary),
        const SizedBox(width: AppSpacing.md),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 15, color: AppColors.text))),
      ]),
    );
  }
}
