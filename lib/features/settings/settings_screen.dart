import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app/config.dart';
import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/auth/session_controller.dart';
import '../../core/device/device_key.dart';
import '../../core/push/push_service.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/states.dart';
import '../home/home_providers.dart';

final myDeviceProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return (await ref.read(apiProvider).rpc('get_my_device_status', {'p_installation_id': await Installation.id()})).map;
});

final _appVersionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version} (${info.buildNumber})';
});

final _pushEnabledProvider = FutureProvider.autoDispose<bool>((ref) => PushService.isEnabled());

/// S20 — password, notifications, this phone's punching key, app version,
/// sign out.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionContextProvider);
    final device = ref.watch(myDeviceProvider);
    final push = ref.watch(_pushEnabledProvider).value ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
        SectionCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(session?.name ?? '', style: Theme.of(context).textTheme.titleMedium),
            Text('${session?.code ?? ''} · ${session?.orgName ?? ''}', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: AppSpacing.md),
            OutlinedButton.icon(
              onPressed: () => context.push('/settings/password'),
              icon: const AppIcon(Icons.password_rounded),
              label: const Text('Change password'),
            ),
          ]),
        ),
        const SizedBox(height: AppSpacing.lg),
        SectionCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Notifications', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            if (PushService.available)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: push,
                title: const Text('Push notifications on this phone'),
                subtitle: const Text('The in-app inbox always has every notification.'),
                onChanged: (on) async {
                  try {
                    final api = ref.read(apiProvider);
                    if (on) {
                      final ok = await PushService.enable(api);
                      if (!ok && context.mounted) {
                        showMessage(context, 'Notifications are blocked for this app in phone settings.', error: true);
                      }
                    } else {
                      await PushService.disable(api);
                    }
                  } on ApiException catch (e) {
                    if (context.mounted) showMessage(context, e.message, error: true);
                  }
                  ref.invalidate(_pushEnabledProvider);
                },
              )
            else
              Text('Push notifications are not set up for this build. The in-app inbox still shows everything.',
                  style: Theme.of(context).textTheme.bodyMedium),
          ]),
        ),
        const SizedBox(height: AppSpacing.lg),
        SectionCard(
          child: AsyncView(
            value: device,
            loading: const SkeletonList(items: 1),
            onRetry: () => ref.invalidate(myDeviceProvider),
            builder: (d) {
              final registered = d['registered'] == true;
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Phone for punching', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.sm),
                if (!registered)
                  Text('No phone is registered. It is set up the first time you check in.',
                      style: Theme.of(context).textTheme.bodyMedium)
                else ...[
                  KeyValueRow('Phone', (d['label'] as String?) ?? 'Registered phone'),
                  KeyValueRow('This phone', d['this_installation'] == true ? 'Yes' : 'No — another phone is registered'),
                  KeyValueRow('Security', d['attestation_level'] == 'hardware'
                      ? 'Hardware key${d['biometric_bound'] == true ? ', fingerprint/face required' : ''}'
                      : 'Test device (staging only)'),
                  KeyValueRow('Registered', OrgTime.dateTime(d['registered_at'])),
                  if (d['last_used_at'] != null) KeyValueRow('Last punch', OrgTime.dateTime(d['last_used_at'])),
                  const SizedBox(height: AppSpacing.sm),
                  OutlinedButton(
                    onPressed: () async {
                      final ok = await confirm(context,
                          title: 'Remove this punching phone?',
                          message: 'Punching stops on that phone until it is registered again at your next check-in.',
                          confirmLabel: 'Remove',
                          destructive: true);
                      if (!ok) return;
                      try {
                        await ref.read(apiProvider).rpc('revoke_device',
                            {'p_device_id': d['device_id'], 'p_reason': 'Removed by the employee in settings'});
                        ref.invalidate(myDeviceProvider);
                        ref.invalidate(homeSummaryProvider);
                      } on ApiException catch (e) {
                        if (context.mounted) showMessage(context, e.message, error: true);
                      }
                    },
                    child: const Text('Remove registered phone'),
                  ),
                ],
              ]);
            },
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        SectionCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('About', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            KeyValueRow('App version', ref.watch(_appVersionProvider).value ?? '…'),
            KeyValueRow('Environment', AppConfig.isProduction ? 'Production' : 'Staging'),
            KeyValueRow('Help', session?.supportContact ?? 'Contact HR'),
          ]),
        ),
        const SizedBox(height: AppSpacing.xl),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          onPressed: () async {
            final ok = await confirm(context,
                title: 'Sign out?',
                message: 'Previews and working files are removed from this phone.',
                confirmLabel: 'Sign out');
            if (ok) await ref.read(sessionProvider.notifier).logout();
          },
          icon: const AppIcon(Icons.logout_rounded),
          label: const Text('Sign out'),
        ),
      ]),
    );
  }
}
