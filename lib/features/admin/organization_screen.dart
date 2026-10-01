import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/auth/session_controller.dart';
import '../../core/format.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/pickers.dart';
import '../../core/widgets/states.dart';

final orgSettingsProvider = FutureProvider.autoDispose<ApiResult>((ref) => ref.read(apiProvider).rpc('get_org_settings'));
final maintenanceHealthProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return (await ref.read(apiProvider).rpc('get_maintenance_health')).map;
});

const _monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October',
  'November', 'December'];

/// S37 — organisation settings (Admin). Secret keys are never shown here;
/// they live only in the server environment.
class OrganizationScreen extends ConsumerStatefulWidget {
  const OrganizationScreen({super.key});

  @override
  ConsumerState<OrganizationScreen> createState() => _OrganizationScreenState();
}

class _OrganizationScreenState extends ConsumerState<OrganizationScreen> {
  final _name = TextEditingController();
  final _tz = TextEditingController();
  final _cap = TextEditingController();
  final _target = TextEditingController();
  final _support = TextEditingController();
  final _budget = TextEditingController();
  int _annual = 1;
  int _leaveYear = 1;
  bool _strict = false;
  bool _biometric = true;
  int? _loadedVersion;
  Map<String, String> _errors = const {};
  bool _busy = false;
  Map<String, dynamic>? _preview;

  @override
  void dispose() {
    for (final c in [_name, _tz, _cap, _target, _support, _budget]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(ApiResult res) {
    if (_loadedVersion == res.version) return;
    final o = res.map;
    _loadedVersion = res.version;
    _name.text = o['name'] as String? ?? '';
    _tz.text = o['timezone'] as String? ?? '';
    _cap.text = '${o['active_employee_cap']}';
    _target.text = '${o['holiday_target']}';
    _support.text = o['support_contact'] as String? ?? '';
    _budget.text = '${((o['storage_budget_bytes'] as num?) ?? 0) ~/ 1000000}';
    _annual = (o['annual_start_month'] as num?)?.toInt() ?? 1;
    _leaveYear = (o['leave_year_start_month'] as num?)?.toInt() ?? 1;
    _strict = o['strict_geofence'] == true;
    _biometric = o['require_biometric_punch'] != false;
  }

  Future<void> _previewCycle(int month) async {
    try {
      final p = (await ref.read(apiProvider).rpc('preview_annual_cycle', {'p_start_month': month})).map;
      if (mounted) setState(() => _preview = p);
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    }
  }

  Future<void> _save(Map<String, dynamic> current, {bool publishSetup = false}) async {
    final patch = <String, dynamic>{
      'name': _name.text.trim(),
      'timezone': _tz.text.trim(),
      'annual_start_month': _annual,
      'leave_year_start_month': _leaveYear,
      'active_employee_cap': int.tryParse(_cap.text.trim()),
      'holiday_target': int.tryParse(_target.text.trim()),
      'support_contact': _support.text.trim(),
      'storage_budget_bytes': ((int.tryParse(_budget.text.trim()) ?? 0) * 1000000),
      'strict_geofence': _strict,
      'require_biometric_punch': _biometric,
      if (publishSetup) 'publish_setup': true,
    }..removeWhere((k, v) => v == null);
    if (_annual != current['annual_start_month']) {
      final ok = await confirm(context,
          title: 'Change the annual archive period?',
          message: 'Existing periods stay exactly as they are. The next period starts with a shorter transition period '
              'so no month is skipped or counted twice.',
          confirmLabel: 'Change');
      if (!ok) return;
    }
    setState(() {
      _busy = true;
      _errors = const {};
    });
    try {
      final res = await ref.read(apiProvider).rpc('update_org_settings', {'p_patch': patch, 'p_expected_version': _loadedVersion});
      _loadedVersion = null;
      _fill(res);
      ref.invalidate(orgSettingsProvider);
      ref.read(sessionProvider.notifier).refreshContext();
      if (mounted) showMessage(context, 'Settings saved.');
    } on ApiException catch (e) {
      setState(() => _errors = e.fieldErrors);
      if (mounted) showMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(orgSettingsProvider);
    final health = ref.watch(maintenanceHealthProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Organisation')),
      body: PermissionGate(
        allowed: (s) => s.isAdmin,
        child: AsyncView(
          value: data,
          onRetry: () => ref.invalidate(orgSettingsProvider),
          builder: (res) {
            _fill(res);
            final o = res.map;
            final used = (o['storage_used_bytes'] as num?) ?? 0;
            return ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
              if (o['setup_published_at'] == null)
                SectionCard(
                  color: AppColors.warningSoft,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Setup checklist', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: AppSpacing.sm),
                    const Text('Before live use: add each office and test it on site, publish shifts, add leave types and '
                        'this year\'s entitlements, publish holidays, set approval routes for every team, and add people. '
                        'Default values are proposals, not company policy.'),
                    const SizedBox(height: AppSpacing.sm),
                    OutlinedButton(
                      onPressed: _busy ? null : () => _save(o, publishSetup: true),
                      child: const Text('Mark setup as reviewed'),
                    ),
                  ]),
                ),
              const SizedBox(height: AppSpacing.lg),
              FormSection(title: 'Organisation', children: [
                TextField(controller: _name, maxLength: 120, decoration: InputDecoration(labelText: 'Display name',
                    errorText: _errors['name'])),
                TextField(controller: _tz, decoration: InputDecoration(labelText: 'Time zone', errorText: _errors['timezone'],
                    helperText: 'Used for business dates, e.g. Asia/Kolkata')),
                TextField(controller: _support, maxLength: 200,
                    decoration: const InputDecoration(labelText: 'Help contact shown to staff')),
              ]),
              const SizedBox(height: AppSpacing.lg),
              FormSection(title: 'Years', children: [
                DropdownButtonFormField<int>(
                  icon: const AppIcon(Icons.keyboard_arrow_down_rounded),
                  initialValue: _annual,
                  decoration: InputDecoration(labelText: 'Annual archive period', errorText: _errors['annual_start_month']),
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('January – December')),
                    DropdownMenuItem(value: 4, child: Text('April – March')),
                  ],
                  onChanged: (v) {
                    setState(() => _annual = v ?? 1);
                    if (v != null && v != o['annual_start_month']) {
                      _previewCycle(v);
                    } else {
                      setState(() => _preview = null);
                    }
                  },
                ),
                if (_preview != null)
                  Text('Next periods: ${((_preview!['next_periods'] as List?) ?? const []).map((p) => '${(p as Map)['label']}'
                      '${p['kind'] == 'transition' ? ' (transition)' : ''}').join(', then ')}',
                      style: Theme.of(context).textTheme.bodySmall),
                DropdownButtonFormField<int>(
                  icon: const AppIcon(Icons.keyboard_arrow_down_rounded),
                  initialValue: _leaveYear,
                  decoration: InputDecoration(labelText: 'Leave year starts in', errorText: _errors['leave_year_start_month']),
                  items: [for (var m = 1; m <= 12; m++) DropdownMenuItem(value: m, child: Text(_monthNames[m - 1]))],
                  onChanged: (v) => setState(() => _leaveYear = v ?? 1),
                ),
                TextField(controller: _target, keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Planned company holidays per year')),
              ]),
              const SizedBox(height: AppSpacing.lg),
              FormSection(title: 'Limits & security', children: [
                TextField(controller: _cap, keyboardType: TextInputType.number, decoration: InputDecoration(
                    labelText: 'Active employee limit', errorText: _errors['active_employee_cap'],
                    helperText: '${o['active_employees']} active now')),
                TextField(controller: _budget, keyboardType: TextInputType.number, decoration: InputDecoration(
                    labelText: 'File storage budget (MB)', errorText: _errors['storage_budget_bytes'],
                    helperText: '${formatBytes(used)} used. Alerts at ${((o['storage_alert_percents'] as List?) ?? const []).join('/')}%. '
                        'Files are never deleted automatically.')),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _biometric,
                  title: const Text('Require fingerprint/face for every punch'),
                  subtitle: const Text('Recommended. The punch key only signs after a fresh biometric check.'),
                  onChanged: (v) => setState(() => _biometric = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _strict,
                  title: const Text('Strict geofence for all offices'),
                  onChanged: (v) => setState(() => _strict = v),
                ),
              ]),
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                onPressed: _busy ? null : () => _save(o),
                child: _busy
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                    : const Text('Save settings'),
              ),
              const SizedBox(height: AppSpacing.xl),
              SectionCard(
                child: AsyncView(
                  value: health,
                  loading: const SkeletonList(items: 1),
                  onRetry: () => ref.invalidate(maintenanceHealthProvider),
                  builder: (h) {
                    final stale = h['stale'] == true;
                    final last = (h['last_tick'] as Map?)?.cast<String, dynamic>();
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text('Background maintenance', style: Theme.of(context).textTheme.titleSmall)),
                        StatusChip(stale ? 'Not running' : 'Healthy', tone: stale ? ChipTone.error : ChipTone.success),
                      ]),
                      const SizedBox(height: AppSpacing.sm),
                      KeyValueRow('Last run', last == null ? 'Never' : OrgTime.dateTime(last['at'])),
                      KeyValueRow('Push queue', '${h['outbox_backlog']} waiting · ${h['outbox_failed']} failed'),
                      KeyValueRow('Uploads in progress', '${h['pending_uploads']}'),
                      if (stale)
                        Text('Scheduled jobs are not reaching the server. Attendance stays correct (stale shifts are '
                            'closed on the next punch), but pushes and clean-up of abandoned uploads wait. Check the '
                            'maintenance secret and scheduler in the Supabase project.',
                            style: Theme.of(context).textTheme.bodySmall),
                    ]);
                  },
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}
