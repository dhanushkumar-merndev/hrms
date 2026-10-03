import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/config.dart';
import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/illustration.dart';

class SupportPhone {
  const SupportPhone._(this.display, this.uri);

  final String display;
  final Uri uri;

  String get digits => uri.path.replaceFirst('+', '');
  Uri get whatsAppUri => Uri.https('wa.me', '/$digits');

  static SupportPhone? parse(String? value) {
    final display = value?.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (display == null ||
        !RegExp(r'^\+[0-9][0-9 ()-]{6,23}$').hasMatch(display)) {
      return null;
    }
    final digits = display.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 8 || digits.length > 15) return null;
    return SupportPhone._(display, Uri.parse('tel:+$digits'));
  }

  static SupportPhone? fromJson(Map<String, dynamic> json) {
    final phone = parse(json['display_phone'] as String?);
    if (phone == null || json['tel_uri'] != phone.uri.toString()) return null;
    return phone;
  }
}

final loginSupportProvider = FutureProvider<SupportPhone?>((ref) async {
  final result = await ref.read(apiProvider).function('public-config', {
    'action': 'login-support',
    'org_code': AppConfig.orgCode,
  }, authenticated: false);
  return SupportPhone.fromJson(result.map);
});

final supportPhoneLauncherProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

final supportPhoneClipboardProvider = Provider<Future<void> Function(String)>(
  (ref) =>
      (value) => Clipboard.setData(ClipboardData(text: value)),
);

class ForgotPasswordSupport extends ConsumerStatefulWidget {
  const ForgotPasswordSupport({super.key});

  @override
  ConsumerState<ForgotPasswordSupport> createState() =>
      _ForgotPasswordSupportState();
}

class _ForgotPasswordSupportState extends ConsumerState<ForgotPasswordSupport> {
  Future<void> _showSupport(SupportPhone phone) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _SupportSheet(phone: phone),
    );
  }

  @override
  Widget build(BuildContext context) {
    final phone = ref.watch(loginSupportProvider).value;
    if (phone == null) {
      return Text(
        'Forgot your password? Contact HR to reset it.',
        style: Theme.of(context).textTheme.bodyMedium,
        textAlign: TextAlign.center,
      );
    }
    return TextButton(
      onPressed: () => _showSupport(phone),
      child: const Text('Forgot your password? Contact HR'),
    );
  }
}

class _SupportSheet extends ConsumerStatefulWidget {
  const _SupportSheet({required this.phone});

  final SupportPhone phone;

  @override
  ConsumerState<_SupportSheet> createState() => _SupportSheetState();
}

class _SupportSheetState extends ConsumerState<_SupportSheet> {
  String? _message;

  Future<void> _launch(Uri uri, String failureMessage) async {
    var opened = false;
    try {
      opened = await ref.read(supportPhoneLauncherProvider)(uri);
    } catch (_) {
      opened = false;
    }
    if (mounted) setState(() => _message = opened ? null : failureMessage);
  }

  Future<void> _copy() async {
    await ref.read(supportPhoneClipboardProvider)(widget.phone.display);
    if (mounted) setState(() => _message = 'Number copied.');
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.xl,
          0,
          AppSpacing.xl,
          AppSpacing.xl + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Illustration('people', size: 88),
            const SizedBox(height: AppSpacing.md),
            Text('Contact HR', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'For password help, contact HR using the official number below.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            SelectableText(
              widget.phone.display,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(color: AppColors.primary),
            ),
            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () =>
                    _launch(widget.phone.uri, 'Could not open the phone app.'),
                icon: const AppIcon(Icons.call_outlined),
                label: const Text('Call HR'),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _launch(
                  widget.phone.whatsAppUri,
                  'Could not open WhatsApp.',
                ),
                icon: const AppIcon(Icons.chat_outlined),
                label: const Text('WhatsApp HR'),
              ),
            ),
            TextButton.icon(
              onPressed: _copy,
              icon: const AppIcon(Icons.copy_outlined),
              label: const Text('Copy number'),
            ),
            if (_message != null)
              Semantics(
                liveRegion: true,
                child: Text(
                  _message!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
