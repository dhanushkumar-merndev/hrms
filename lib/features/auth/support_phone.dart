import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/config.dart';
import '../../core/api/api_client.dart';

class SupportPhone {
  const SupportPhone._(this.display, this.uri);

  final String display;
  final Uri uri;

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
  bool _showCopy = false;
  bool _copied = false;

  Future<void> _open(SupportPhone phone) async {
    var opened = false;
    try {
      opened = await ref.read(supportPhoneLauncherProvider)(phone.uri);
    } catch (_) {
      opened = false;
    }
    if (mounted && !opened) setState(() => _showCopy = true);
  }

  Future<void> _copy(SupportPhone phone) async {
    await ref.read(supportPhoneClipboardProvider)(phone.display);
    if (mounted) setState(() => _copied = true);
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
    return Column(
      children: [
        const Text('Forgot your password? Contact HR:'),
        TextButton(onPressed: () => _open(phone), child: Text(phone.display)),
        if (_showCopy)
          TextButton(
            onPressed: () => _copy(phone),
            child: const Text('Copy number'),
          ),
        if (_copied) const Text('Number copied.'),
      ],
    );
  }
}
