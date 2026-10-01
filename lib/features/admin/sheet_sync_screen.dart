import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/states.dart';

final sheetSyncProvider = FutureProvider.autoDispose<(ApiResult, Map<String, dynamic>)>((ref) async {
  final api = ref.read(apiProvider);
  final config = await api.rpc('get_sheet_sync');
  Map<String, dynamic> status;
  try {
    status = (await api.function('sheets-sync', {'action': 'status'})).map;
  } on ApiException {
    status = const {'configured': false};
  }
  return (config, status);
});

/// Admin — keeps one company Google Sheet up to date (a tab each for
/// employees, attendance, leave & requests, approvals, balances, roles,
/// teams and — only after a password check — salary). The server writes it
/// with its own Google service account; nobody signs in to Google here.
class SheetSyncScreen extends ConsumerStatefulWidget {
  const SheetSyncScreen({super.key});

  @override
  ConsumerState<SheetSyncScreen> createState() => _SheetSyncScreenState();
}

class _SheetSyncScreenState extends ConsumerState<SheetSyncScreen> {
  final _link = TextEditingController();
  bool? _enabled;
  bool? _salary;
  bool _busy = false;
  bool _filled = false;
  String? _fieldError;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _save(int version, {required bool enabled, required bool salary, required bool hadSalary}) async {
    setState(() {
      _busy = true;
      _fieldError = null;
    });
    try {
      Future<void> call() => ref.read(apiProvider).rpc('set_sheet_sync', {
            'p_spreadsheet_id': _link.text.trim(),
            'p_enabled': enabled,
            'p_include_salary': salary,
            'p_expected_version': version,
          });
      try {
        await call();
      } on ApiException catch (e) {
        if (e.code != 'REAUTH_REQUIRED' || !mounted) rethrow;
        if (!await reauthenticate(context, ref, action: 'export.bulk_salary')) return;
        await call();
      }
      ref.invalidate(sheetSyncProvider);
      if (mounted) showMessage(context, enabled ? 'Saved. The sheet updates within a minute.' : 'Saved. Syncing is off.');
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _fieldError = e.fieldErrors['spreadsheet_id']);
        showMessage(context, e.message, error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    try {
      final res = (await ref.read(apiProvider).function('sheets-sync', {'action': 'sync'})).map;
      if (mounted) showMessage(context, 'Sheet updated (${res['rows']} rows).');
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    } finally {
      ref.invalidate(sheetSyncProvider);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(sheetSyncProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Google Sheet')),
      body: PermissionGate(
        allowed: (s) => s.isAdmin,
        child: AsyncView(
          value: data,
          onRetry: () => ref.invalidate(sheetSyncProvider),
          builder: (v) {
            final (res, status) = v;
            final c = res.map;
            final version = res.version ?? 0;
            if (!_filled) {
              _filled = true;
              _link.text = (c['spreadsheet_id'] as String?) == null
                  ? ''
                  : 'https://docs.google.com/spreadsheets/d/${c['spreadsheet_id']}';
            }
            final enabled = _enabled ?? (c['enabled'] == true);
            final salary = _salary ?? (c['include_salary'] == true);
            final configured = status['configured'] == true;
            final email = status['service_account_email'] as String?;
            final t = Theme.of(context).textTheme;
            return RefreshIndicator(
              onRefresh: () async => ref.invalidate(sheetSyncProvider),
              child: ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
                _StatusCard(config: c, configured: configured),
                const SizedBox(height: AppSpacing.lg),
                _Step(n: 1, title: 'Create a Google Sheet', body: 'Open Google Sheets on a computer or phone and create an empty sheet, '
                    'e.g. "HRMS live data".'),
                _Step(
                  n: 2,
                  title: 'Share it with the app',
                  body: configured
                      ? 'Share → add this address as Editor:'
                      : 'The server is not connected to Google yet. The developer must add the Google service-account key '
                          '(HRMS_SHEETS_SERVICE_ACCOUNT_B64) and deploy.',
                  child: configured && email != null
                      ? Container(
                          margin: const EdgeInsets.only(top: AppSpacing.sm),
                          padding: const EdgeInsets.only(left: AppSpacing.md),
                          decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(12)),
                          child: Row(children: [
                            Expanded(child: SelectableText(email, style: const TextStyle(fontSize: 13))),
                            IconButton(
                              tooltip: 'Copy address',
                              icon: const AppIcon(Icons.copy_rounded),
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: email));
                                showMessage(context, 'Address copied.');
                              },
                            ),
                          ]),
                        )
                      : null,
                ),
                _Step(
                  n: 3,
                  title: 'Paste the sheet link',
                  body: 'Copy the link from the browser address bar.',
                  child: Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    child: TextField(
                      controller: _link,
                      decoration: InputDecoration(
                        labelText: 'Sheet link',
                        hintText: 'https://docs.google.com/spreadsheets/d/…',
                        errorText: _fieldError,
                        suffixIcon: IconButton(
                          tooltip: 'Paste',
                          icon: const AppIcon(Icons.content_paste_rounded),
                          onPressed: () async {
                            final clip = await Clipboard.getData(Clipboard.kTextPlain);
                            if (clip?.text != null) setState(() => _link.text = clip!.text!.trim());
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                SectionCard(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                  child: Column(children: [
                    SwitchListTile(
                      title: const Text('Keep the sheet updated'),
                      subtitle: const Text('Within a minute of changes, and at least every 30 minutes'),
                      value: enabled,
                      onChanged: _busy ? null : (v) => setState(() => _enabled = v),
                    ),
                    const Divider(indent: 16, endIndent: 16),
                    SwitchListTile(
                      title: const Text('Include a Salary tab'),
                      subtitle: const Text('Monthly salary, bank (last 4 digits) and total paid. Anyone who can open '
                          'the sheet can see it. Needs your password.'),
                      value: salary,
                      onChanged: _busy ? null : (v) => setState(() => _salary = v),
                    ),
                  ]),
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _save(version, enabled: enabled, salary: salary, hadSalary: c['include_salary'] == true),
                  child: const Text('Save'),
                ),
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton.icon(
                  onPressed: _busy || c['enabled'] != true || !configured ? null : _syncNow,
                  icon: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const AppIcon(Icons.sync_rounded),
                  label: const Text('Sync now'),
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'Tabs: Overview, Employees, Attendance (this and last month), Leave & Requests, Approvals, '
                  'Leave Balances, Roles & Access, Teams${salary ? ', Salary' : ''}. The app rewrites them on every '
                  'sync, so edits made in the sheet are replaced. Other tabs you add are left alone.',
                  style: t.bodySmall,
                ),
              ]),
            );
          },
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.config, required this.configured});
  final Map<String, dynamic> config;
  final bool configured;

  @override
  Widget build(BuildContext context) {
    final enabled = config['enabled'] == true;
    final error = config['last_error'] as String?;
    final synced = config['last_synced_at'] as String?;
    final (bg, fg, icon, title) = !configured
        ? (AppColors.warningSoft, AppColors.warning, Icons.cloud_off_rounded, 'Google access not set up on the server')
        : !enabled
            ? (AppColors.background, AppColors.textSecondary, Icons.pause_circle_outline_rounded, 'Syncing is off')
            : error != null
                ? (AppColors.errorSoft, AppColors.error, Icons.sync_problem_rounded, 'Last sync failed')
                : synced == null
                    ? (AppColors.attendanceCard, AppColors.primary, Icons.hourglass_top_rounded, 'Waiting for the first sync')
                    : (AppColors.successSoft, AppColors.success, Icons.cloud_done_rounded, 'Sheet is up to date');
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(AppSpacing.cardRadius)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AppIcon(icon, color: fg, size: 30),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 16)),
            if (synced != null)
              Text('Last synced ${OrgTime.dateTime(synced)}${config['last_rows'] != null ? ' · ${config['last_rows']} rows' : ''}',
                  style: Theme.of(context).textTheme.bodySmall),
            if (error != null) Text(error, style: TextStyle(color: fg, fontSize: 13)),
          ]),
        ),
      ]),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.title, required this.body, this.child});
  final int n;
  final String title;
  final String body;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: AppColors.primary,
          child: Text('$n', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            Text(body, style: Theme.of(context).textTheme.bodyMedium),
            ?child,
          ]),
        ),
      ]),
    );
  }
}
