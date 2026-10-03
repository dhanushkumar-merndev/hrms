import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/auth/session_controller.dart';
import '../../core/format.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/accordion.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/pickers.dart';
import '../../core/widgets/states.dart';
import '../../core/widgets/pill_tabs.dart';
import '../documents/documents_screen.dart';
import '../files/file_viewer_screen.dart';
import '../leave/leave_apply_screen.dart';
import '../people/people_screen.dart';
import '../people/profile_screen.dart';
import '../salary/employee_salary_section.dart';
import 'employee_new_screen.dart';

final employeeProvider = FutureProvider.autoDispose.family<ApiResult, String>((ref, id) {
  return ref.read(apiProvider).rpc('get_employee', {'p_employee_id': id});
});

final employeeFilesProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) async {
  return (await ref.read(apiProvider).rpc('list_employee_files', {'p_employee_id': id})).map;
});

/// S26 — full HR record. Every read and change is authorised and audited on
/// the server; payroll documents appear only with the payroll grant.
class EmployeeDetailScreen extends ConsumerStatefulWidget {
  const EmployeeDetailScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<EmployeeDetailScreen> createState() => _EmployeeDetailScreenState();
}

class _EmployeeDetailScreenState extends ConsumerState<EmployeeDetailScreen> {
  /// Accordion: one section open at a time.
  String? _open = 'employment';
  void _toggle(String key) => setState(() => _open = _open == key ? null : key);
  bool _busy = false;
  String? _resetOperation;

  ApiClient get _api => ref.read(apiProvider);

  void _reload() {
    ref.invalidate(employeeProvider(widget.id));
    ref.invalidate(employeeFilesProvider(widget.id));
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    setState(() => _busy = true);
    try {
      await action();
      _reload();
      if (mounted && done != null) showMessage(context, done);
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
      if (e.code == 'STALE_VERSION') _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editEmployment(Map<String, dynamic> e, int? version) async {
    final structure = ref.read(orgStructureProvider).value;
    final name = TextEditingController(text: e['name'] as String?);
    final designation = TextEditingController(text: e['designation'] as String?);
    final email = TextEditingController(text: e['business_email'] as String?);
    final phone = TextEditingController(text: e['business_phone'] as String?);
    String? dept = (e['department'] as Map?)?['id'] as String?;
    DateTime? join = DateTime.tryParse(e['join_date'] as String? ?? '');
    final save = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(AppSpacing.page),
              children: [
                Text('Employment details', style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: name,
                  maxLength: 200,
                  decoration: const InputDecoration(labelText: 'Full name'),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: designation,
                  maxLength: 120,
                  decoration: const InputDecoration(labelText: 'Designation'),
                ),
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String?>(
                  icon: const AppIcon(Icons.keyboard_arrow_down_rounded),
                  initialValue: dept,
                  decoration: const InputDecoration(labelText: 'Department'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('None')),
                    for (final d in structureList(structure, 'departments'))
                      DropdownMenuItem(value: d['id'] as String, child: Text(d['name'] as String)),
                  ],
                  onChanged: (v) => setState(() => dept = v),
                ),
                const SizedBox(height: AppSpacing.md),
                DateField(label: 'Joining date', date: join, onChanged: (d) => setState(() => join = d)),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: email,
                  maxLength: 200,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Work email'),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: phone,
                  maxLength: 40,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Work phone'),
                ),
                const SizedBox(height: AppSpacing.md),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
              ],
            ),
          );
        },
      ),
    );
    final patch = {
      'full_name': name.text.trim(),
      'designation': designation.text.trim(),
      'department_id': dept ?? '',
      'business_email': email.text.trim(),
      'business_phone': phone.text.trim(),
      if (join != null) 'join_date': OrgTime.ymd(join!),
    };
    for (final c in [name, designation, email, phone]) {
      c.dispose();
    }
    if (save != true) return;
    await _run(
      () => _api.rpc('update_employee', {'p_employee_id': widget.id, 'p_patch': patch, 'p_expected_version': version}),
      done: 'Saved.',
    );
  }

  /// Effective-dated team / office / shift change.
  Future<void> _assign(String kind) async {
    final structure = ref.read(orgStructureProvider).value;
    final key = switch (kind) {
      'team' => 'teams',
      'office' => 'offices',
      _ => 'shifts',
    };
    final options = structureList(structure, key).where((x) => x['active'] == true).toList();
    String? value;
    final today = OrgTime.today();
    DateTime from = kind == 'shift' ? today.add(const Duration(days: 1)) : today;
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            title: Text('Change $kind'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    icon: const AppIcon(Icons.keyboard_arrow_down_rounded),
                    initialValue: value,
                    decoration: InputDecoration(labelText: 'New $kind'),
                    items: [
                      for (final o in options)
                        DropdownMenuItem(value: o['id'] as String, child: Text(o['name'] as String)),
                    ],
                    onChanged: (v) => setState(() => value = v),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  DateField(
                    label: 'Effective from',
                    date: from,
                    first: kind == 'shift'
                        ? today.add(const Duration(days: 1))
                        : today.subtract(const Duration(days: 365)),
                    onChanged: (d) => setState(() => from = d),
                  ),
                  if (kind != 'team')
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.sm),
                      child: Text(
                        'Days already scheduled keep their recorded ${kind == 'office' ? 'office' : 'shift'}; '
                        'the change applies to future days.',
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                    ),
                  TextField(
                    controller: reason,
                    maxLength: 500,
                    decoration: const InputDecoration(labelText: 'Reason'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: value == null ? null : () => Navigator.pop(ctx, true), child: const Text('Save')),
            ],
          );
        },
      ),
    );
    final why = reason.text.trim();
    reason.dispose();
    if (ok != true || value == null) return;
    final fn = switch (kind) {
      'team' => 'set_employee_team',
      'office' => 'set_employee_office',
      _ => 'set_employee_shift',
    };
    final param = switch (kind) {
      'team' => 'p_team_id',
      'office' => 'p_office_id',
      _ => 'p_shift_id',
    };
    await _run(
      () => _api.rpc(fn, {
        'p_employee_id': widget.id,
        param: value,
        'p_effective_from': OrgTime.ymd(from),
        'p_reason': why.isEmpty ? null : why,
      }),
      done: 'Updated.',
    );
  }

  Future<void> _resetPassword(Map<String, dynamic> e) async {
    final roles = ((e['roles'] as List?) ?? const []).cast<String>();
    final ok = await confirm(
      context,
      title: 'Reset password for ${e['name']}?',
      message:
          'Their current sessions end immediately. You will see a new temporary password once; '
          'they must choose their own password at next sign-in.',
      confirmLabel: 'Reset password',
      destructive: true,
    );
    if (!ok || !mounted) return;
    if (roles.contains('admin') &&
        !await reauthenticate(context, ref, action: 'credentials.reset_admin', targetId: widget.id)) {
      return;
    }
    setState(() => _busy = true);
    _resetOperation ??= ApiClient.newOperationKey();
    try {
      final res = (await _api.function('admin-users', {
        'action': 'reset',
        'operation_id': _resetOperation,
        'employee_id': widget.id,
      })).map;
      _resetOperation = null;
      if (mounted) {
        await showTemporaryPassword(
          context,
          code: res['employee_code'] as String,
          password: res['temporary_password'] as String,
        );
      }
      _reload();
    } on ApiException catch (err) {
      if (!err.retryable) _resetOperation = null;
      if (mounted) showMessage(context, err.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setStatus(Map<String, dynamic> e, int? version, bool activate) async {
    final reason = await askReason(
      context,
      title: activate ? 'Reactivate ${e['name']}?' : 'Deactivate ${e['name']}?',
      message: activate
          ? 'They can sign in again with their existing password.'
          : 'They are signed out everywhere and can no longer sign in, punch or approve. '
                'All their records are kept. Their end date is set to today.',
      confirmLabel: activate ? 'Reactivate' : 'Deactivate',
      destructive: !activate,
    );
    if (reason == null) return;
    setState(() => _busy = true);
    try {
      final res = (await _api.rpc('set_employee_status', {
        'p_employee_id': widget.id,
        'p_status': activate ? 'active' : 'inactive',
        'p_end_date': activate ? null : OrgTime.ymd(OrgTime.today()),
        'p_reason': reason,
        'p_expected_version': version,
      })).map;
      _reload();
      final pending = ((res['pending_reviews_to_reassign'] as List?) ?? const []).length;
      if (mounted && pending > 0) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Requests need a new approver'),
            content: Text(
              '$pending pending request(s) were assigned to this person. An Admin should reassign them '
              'from Review requests.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  context.push('/approvals');
                },
                child: const Text('Open reviews'),
              ),
            ],
          ),
        );
      }
    } on ApiException catch (err) {
      if (mounted) showMessage(context, err.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _adjustLeave() async {
    final types = (await ref.read(leaveTypesProvider.future)).where((t) => t['paid'] == true).toList();
    if (!mounted) return;
    String? typeId = types.isEmpty ? null : types.first['id'] as String;
    final year = TextEditingController(text: '${OrgTime.today().year}');
    final days = TextEditingController();
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            title: const Text('Adjust leave balance'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    icon: const AppIcon(Icons.keyboard_arrow_down_rounded),
                    initialValue: typeId,
                    decoration: const InputDecoration(labelText: 'Leave type'),
                    items: [
                      for (final t in types)
                        DropdownMenuItem(value: t['id'] as String, child: Text(t['name'] as String)),
                    ],
                    onChanged: (v) => setState(() => typeId = v),
                  ),
                  TextField(
                    controller: year,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Leave year'),
                  ),
                  TextField(
                    controller: days,
                    keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Days (e.g. 1.5 or -1)',
                      helperText: 'Half days allowed',
                    ),
                  ),
                  TextField(
                    controller: reason,
                    maxLength: 500,
                    decoration: const InputDecoration(labelText: 'Reason'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Adjust')),
            ],
          );
        },
      ),
    );
    final d = double.tryParse(days.text.trim());
    final y = int.tryParse(year.text.trim());
    final why = reason.text.trim();
    for (final c in [year, days, reason]) {
      c.dispose();
    }
    if (ok != true) return;
    if (typeId == null || d == null || y == null || (d * 2) != (d * 2).roundToDouble() || d == 0) {
      if (mounted) {
        showMessage(context, 'Enter a leave year and a non-zero number of days in half-day steps.', error: true);
      }
      return;
    }
    await _run(
      () => _api.rpc('adjust_leave_balance', {
        'p_employee_id': widget.id,
        'p_leave_type_id': typeId,
        'p_leave_year': y,
        'p_units': (d * 2).round(),
        'p_reason': why,
      }),
      done: 'Balance adjusted.',
    );
  }

  Future<void> _scheduleException() async {
    final shifts = structureList(
      ref.read(orgStructureProvider).value,
      'shifts',
    ).where((s) => s['active'] == true).toList();
    DateTime date = OrgTime.today().add(const Duration(days: 1));
    String kind = 'day_off';
    String? shiftId = shifts.isEmpty ? null : shifts.first['id'] as String;
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            title: const Text('Schedule exception'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DateField(
                    label: 'Date',
                    date: date,
                    first: OrgTime.today().add(const Duration(days: 1)),
                    onChanged: (d) => setState(() => date = d),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  PillTabs<String>(
                    options: const [('day_off', 'Day off'), ('extra_workday', 'Extra workday')],
                    value: kind,
                    onChanged: (v) => setState(() => kind = v),
                  ),
                  if (kind == 'extra_workday')
                    DropdownButtonFormField<String>(
                      icon: const AppIcon(Icons.keyboard_arrow_down_rounded),
                      initialValue: shiftId,
                      decoration: const InputDecoration(labelText: 'Shift'),
                      items: [
                        for (final s in shifts)
                          DropdownMenuItem(value: s['id'] as String, child: Text(s['name'] as String)),
                      ],
                      onChanged: (v) => setState(() => shiftId = v),
                    ),
                  TextField(
                    controller: reason,
                    maxLength: 500,
                    decoration: const InputDecoration(labelText: 'Reason'),
                  ),
                  Text('Exceptions never override approved leave.', style: Theme.of(ctx).textTheme.bodySmall),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
            ],
          );
        },
      ),
    );
    final why = reason.text.trim();
    reason.dispose();
    if (ok != true) return;
    await _run(
      () => _api.rpc('save_schedule_exception', {
        'p_employee_id': widget.id,
        'p_work_date': OrgTime.ymd(date),
        'p_kind': kind,
        'p_shift_id': kind == 'extra_workday' ? shiftId : null,
        'p_reason': why,
      }),
      done: 'Exception saved.',
    );
  }

  Future<void> _revokeDevice(String deviceId) async {
    final reason = await askReason(
      context,
      title: 'Remove this punching phone?',
      message: 'The employee must register a phone again before their next check-in.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (reason == null) return;
    await _run(() => _api.rpc('revoke_device', {'p_device_id': deviceId, 'p_reason': reason}), done: 'Phone removed.');
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(employeeProvider(widget.id));
    final session = ref.watch(sessionContextProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Employee')),
      body: PermissionGate(
        allowed: (s) => s.canViewEmployees,
        child: AsyncView(
          value: data,
          onRetry: _reload,
          loading: const ProfileSkeleton(),
          builder: (res) {
            final e = res.map;
            final version = res.version;
            final canEdit = e['can_edit'] == true;
            final roles = ((e['roles'] as List?) ?? const []).cast<String>();
            final perms = ((e['permissions'] as List?) ?? const []).cast<String>();
            final private = ((e['private'] as Map?) ?? const {}).cast<String, dynamic>();
            final active = e['status'] == 'active';
            List<Map<String, dynamic>> hist(String k) =>
                ((e[k] as List?) ?? const []).map((x) => (x as Map).cast<String, dynamic>()).toList();
            String range(Map<String, dynamic> h) =>
                '${OrgTime.date(h['from'] as String?, pattern: 'd MMM yyyy')} – '
                '${h['to'] == null ? 'now' : OrgTime.date(h['to'] as String?, pattern: 'd MMM yyyy')}';
            String current(String listKey, String nameKey) =>
                (hist(listKey).where((h) => h['to'] == null).firstOrNull?[nameKey] as String?) ?? 'Not assigned';
            Widget history(String title, IconData icon, String kind, String listKey, String nameKey) =>
                AccordionSection(
                  title: title,
                  icon: icon,
                  summary: current(listKey, nameKey),
                  expanded: _open == kind,
                  onToggle: () => _toggle(kind),
                  action: canEdit && active
                      ? TextButton(onPressed: _busy ? null : () => _assign(kind), child: const Text('Change'))
                      : null,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final h in hist(listKey)) KeyValueRow(h[nameKey] as String? ?? '—', range(h)),
                      if (hist(listKey).isEmpty) Text('Not assigned', style: Theme.of(context).textTheme.bodyMedium),
                    ],
                  ),
                );
            final dept = ((e['department'] as Map?)?['name'] as String?) ?? 'No department';
            final activePhones = hist('devices').where((d) => d['revoked_at'] == null).length;
            return RefreshIndicator(
              onRefresh: () async => _reload(),
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.page),
                children: [
                  SectionCard(
                    child: Row(
                      children: [
                        AvatarImage(
                          fileVersionId: e['avatar_file_version_id'] as String?,
                          name: e['name'] as String? ?? '',
                        ),
                        const SizedBox(width: AppSpacing.lg),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e['name'] as String? ?? '', style: Theme.of(context).textTheme.titleLarge),
                              Text('${e['code']}${e['designation'] != null ? ' · ${e['designation']}' : ''}'),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  StatusChip(
                                    active ? 'Active' : (e['status'] as String? ?? '').toUpperCase(),
                                    tone: active ? ChipTone.success : ChipTone.neutral,
                                  ),
                                  for (final r in roles) StatusChip(roleLabel(r), tone: ChipTone.info),
                                  if (e['must_change_password'] == true)
                                    const StatusChip('First sign-in pending', tone: ChipTone.warning),
                                  if (e['credential_hold'] == true)
                                    const StatusChip('Password change in progress', tone: ChipTone.warning),
                                  if (e['alias_anomaly_at'] != null)
                                    const StatusChip('Login identity needs repair', tone: ChipTone.error),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  AccordionSection(
                    title: 'Employment',
                    icon: Icons.badge_outlined,
                    summary: '$dept · joined ${OrgTime.date(e['join_date'] as String?, pattern: 'd MMM yyyy')}',
                    expanded: _open == 'employment',
                    onToggle: () => _toggle('employment'),
                    action: canEdit
                        ? TextButton(
                            onPressed: _busy ? null : () => _editEmployment(e, version),
                            child: const Text('Edit'),
                          )
                        : null,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        KeyValueRow('Department', ((e['department'] as Map?)?['name'] as String?) ?? '—'),
                        KeyValueRow('Joined', OrgTime.date(e['join_date'] as String?)),
                        if (e['end_date'] != null) KeyValueRow('Left', OrgTime.date(e['end_date'] as String?)),
                        KeyValueRow('Work email', (e['business_email'] as String?) ?? '—'),
                        KeyValueRow('Work phone', (e['business_phone'] as String?) ?? '—'),
                        if (perms.isNotEmpty) KeyValueRow('Extra access', perms.map(permissionLabel).join(', ')),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  history('Team', Icons.groups_outlined, 'team', 'teams', 'team'),
                  const SizedBox(height: AppSpacing.md),
                  history('Office', Icons.location_on_outlined, 'office', 'offices', 'office'),
                  const SizedBox(height: AppSpacing.md),
                  history('Shift', Icons.schedule_rounded, 'shift', 'shifts', 'shift'),
                  const SizedBox(height: AppSpacing.md),
                  AccordionSection(
                    title: 'Personal details',
                    icon: Icons.person_outline_rounded,
                    tint: AppColors.peopleCard,
                    iconColor: AppColors.peopleAction,
                    summary: 'Contact, address and emergency details',
                    expanded: _open == 'personal',
                    onToggle: () => _toggle('personal'),
                    action: canEdit
                        ? TextButton(
                            onPressed: () async {
                              final saved = await showPrivateDetailsEditor(
                                context,
                                ref,
                                private: private,
                                own: false,
                                employeeId: widget.id,
                              );
                              if (saved) _reload();
                            },
                            child: const Text('Edit'),
                          )
                        : null,
                    child: PrivateDetailsView(private: private),
                  ),
                  if (session?.canManagePayroll ?? false) ...[
                    const SizedBox(height: AppSpacing.lg),
                    EmployeeSalarySection(employeeId: widget.id, employeeName: e['name'] as String? ?? ''),
                    const SizedBox(height: AppSpacing.lg),
                  ] else
                    const SizedBox(height: AppSpacing.md),
                  AccordionSection(
                    title: (session?.canManagePayroll ?? false) ? 'Documents & payslips' : 'Documents',
                    icon: Icons.folder_outlined,
                    tint: AppColors.documentsCard,
                    iconColor: AppColors.documentsAction,
                    summary: 'PDF files, up to $documentLimit',
                    expanded: _open == 'files',
                    onToggle: () => _toggle('files'),
                    child: _FilesSection(employeeId: widget.id, onChanged: _reload),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AccordionSection(
                    title: 'Punching phones',
                    icon: Icons.smartphone_rounded,
                    tint: AppColors.approvalsCard,
                    iconColor: AppColors.approvalsAction,
                    summary: activePhones == 0 ? 'None registered' : '$activePhones active',
                    expanded: _open == 'phones',
                    onToggle: () => _toggle('phones'),
                    child: _DevicesSection(
                      devices: hist('devices'),
                      canEdit: canEdit,
                      onRevoke: _busy ? null : _revokeDevice,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AccordionSection(
                    title: 'Actions',
                    icon: Icons.tune_rounded,
                    tint: AppColors.workspaceCard,
                    iconColor: AppColors.workspaceAction,
                    summary: 'Hours, leave, password and status',
                    expanded: _open == 'actions',
                    onToggle: () => _toggle('actions'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => context.push('/reports/hours?employee=${widget.id}'),
                          icon: const AppIcon(Icons.schedule_rounded),
                          label: const Text('Attendance & hours'),
                        ),
                        if (canEdit && active) ...[
                          const SizedBox(height: AppSpacing.sm),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _scheduleException,
                            icon: const AppIcon(Icons.event_busy_outlined),
                            label: const Text('Schedule exception'),
                          ),
                        ],
                        if (session?.isAdmin ?? false) ...[
                          const SizedBox(height: AppSpacing.sm),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _adjustLeave,
                            icon: const AppIcon(Icons.exposure_rounded),
                            label: const Text('Adjust leave balance'),
                          ),
                        ],
                        if ((session?.canProvision ?? false) && active && e['provisioning_state'] == 'complete') ...[
                          const SizedBox(height: AppSpacing.sm),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : () => _resetPassword(e),
                            icon: const AppIcon(Icons.lock_reset_rounded),
                            label: const Text('Reset password'),
                          ),
                        ],
                        if (canEdit && widget.id != session?.employeeId) ...[
                          const SizedBox(height: AppSpacing.sm),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: active ? AppColors.error : AppColors.success,
                            ),
                            onPressed: _busy ? null : () => _setStatus(e, version, !active),
                            icon: AppIcon(active ? Icons.person_off_outlined : Icons.person_outline_rounded),
                            label: Text(active ? 'Deactivate' : 'Reactivate'),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _FilesSection extends ConsumerWidget {
  const _FilesSection({required this.employeeId, required this.onChanged});
  final String employeeId;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref.watch(employeeFilesProvider(employeeId));
    return AsyncView(
      value: files,
      loading: const SkeletonList(items: 1),
      onRetry: () => ref.invalidate(employeeFilesProvider(employeeId)),
      builder: (d) {
        final docs = ((d['documents'] as List?) ?? const []).map((x) => (x as Map).cast<String, dynamic>()).toList();
        final slips = (d['payslips'] as List?)?.map((x) => (x as Map).cast<String, dynamic>()).toList();
        final count = (d['document_count'] as num?)?.toInt() ?? docs.length;
        final limit = (d['document_limit'] as num?)?.toInt() ?? documentLimit;
        final canUpload = d['can_upload'] == true;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DocumentQuotaHeader(
              title: 'Documents',
              count: count,
              limit: limit,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            if (docs.isEmpty) Text('No documents.', style: Theme.of(context).textTheme.bodyMedium),
            for (final doc in docs)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const AppIcon(Icons.picture_as_pdf_outlined),
                title: Text(doc['title'] as String? ?? 'Document', maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  [
                    if (doc['document_date'] != null)
                      OrgTime.date(doc['document_date'] as String?, pattern: 'd MMM yyyy'),
                    doc['state'] == 'deleted' ? 'Archived locally' : formatBytes(doc['size_bytes'] as num?),
                    if (doc['added_by_employee'] == true) 'Added by employee',
                  ].join(' · '),
                ),
                trailing: doc['can_edit'] == true
                    ? DocumentMenu(
                        onRename: () async {
                          if (await renameDocument(context, ref, doc)) onChanged();
                        },
                        onRemove: () async {
                          if (await removeDocument(context, ref, doc)) onChanged();
                        },
                      )
                    : null,
                onTap: doc['state'] == 'deleted'
                    ? null
                    : () => openProtectedFile(
                        context,
                        doc['file_version_id'] as String,
                        doc['title'] as String? ?? 'Document',
                      ),
              ),
            if (canUpload) ...[
              const SizedBox(height: AppSpacing.sm),
              AddDocumentButton(
                count: count,
                limit: limit,
                onPressed: () async {
                  if (await uploadAndPublishDocument(
                    context,
                    ref,
                    fileClass: 'employee_document',
                    ownerEmployeeId: employeeId,
                    askDate: true,
                  )) {
                    onChanged();
                  }
                },
              ),
            ],
            if (slips != null) ...[
              const Divider(height: AppSpacing.xl),
              Row(
                children: [
                  Expanded(child: Text('Payslips', style: Theme.of(context).textTheme.titleSmall)),
                  TextButton(
                    onPressed: () => context.push('/payroll/uploads?employee=$employeeId'),
                    child: const Text('Manage'),
                  ),
                ],
              ),
              if (slips.isEmpty) Text('No payslips uploaded.', style: Theme.of(context).textTheme.bodyMedium),
              for (final s in slips.take(12))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const AppIcon(Icons.receipt_long_outlined),
                  title: Text(monthLabel(s['salary_month'])),
                  subtitle: Text(switch (s['state']) {
                    'published' => 'Published',
                    'deleted' || 'deletion_pending' => 'Archived locally',
                    null => 'Draft only',
                    final x => x.toString(),
                  }),
                  onTap: s['state'] == 'published'
                      ? () => openProtectedFile(
                          context,
                          s['file_version_id'] as String,
                          'Payslip · ${monthLabel(s['salary_month'])}',
                        )
                      : null,
                ),
            ],
          ],
        );
      },
    );
  }
}

class _DevicesSection extends StatelessWidget {
  const _DevicesSection({required this.devices, required this.canEdit, required this.onRevoke});
  final List<Map<String, dynamic>> devices;
  final bool canEdit;
  final void Function(String id)? onRevoke;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (devices.isEmpty) Text('None registered.', style: Theme.of(context).textTheme.bodyMedium),
        for (final d in devices)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: AppIcon(d['revoked_at'] == null ? Icons.smartphone_rounded : Icons.phonelink_erase_rounded),
            title: Text((d['label'] as String?) ?? d['platform'] as String? ?? 'Phone'),
            subtitle: Text(
              d['revoked_at'] == null
                  ? 'Active · ${d['attestation_level'] == 'hardware' ? 'hardware key' : 'test device'} · '
                        'registered ${OrgTime.dateTime(d['registered_at'])}'
                  : 'Removed ${OrgTime.dateTime(d['revoked_at'])}${d['revoke_reason'] != null ? ' — ${d['revoke_reason']}' : ''}',
            ),
            trailing: canEdit && d['revoked_at'] == null && onRevoke != null
                ? IconButton(
                    tooltip: 'Remove phone',
                    onPressed: () => onRevoke!(d['id'] as String),
                    icon: const AppIcon(Icons.delete_outline_rounded),
                  )
                : null,
          ),
      ],
    );
  }
}
