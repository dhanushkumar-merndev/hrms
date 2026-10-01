import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/format.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/states.dart';

final accessGrantsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  return (await ref.read(apiProvider).rpc('list_access_grants')).list;
});

const _grantable = [
  'payroll.manage',
  'documents.medical',
  'hr.employees.provision',
  'hr.master_data',
  'policy.draft',
  'audit.scoped',
  'announcements.publish',
];

/// Grants that need a fresh password confirmation (server-enforced).
bool _sensitive(String roleOrPermission) =>
    const {'hr', 'admin', 'payroll.manage', 'documents.medical'}.contains(roleOrPermission);

/// S33 — roles and delegated permissions (Admin only). Elevation needs a
/// recent password confirmation; the last active Admin cannot be removed.
class PermissionsScreen extends ConsumerStatefulWidget {
  const PermissionsScreen({super.key});

  @override
  ConsumerState<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends ConsumerState<PermissionsScreen> {
  String _query = '';
  bool _busy = false;

  Future<void> _change({
    required Map<String, dynamic> employee,
    required String what,
    required bool enable,
    required bool isRole,
  }) async {
    final label = isRole ? roleLabel(what) : permissionLabel(what);
    final reason = await askReason(context,
        title: '${enable ? 'Give' : 'Remove'} "$label" ${enable ? 'to' : 'from'} ${employee['name']}?',
        confirmLabel: enable ? 'Give access' : 'Remove access',
        destructive: !enable);
    if (reason == null || !mounted) return;
    if (enable && _sensitive(what) &&
        !await reauthenticate(context, ref, action: 'role.elevate', targetId: employee['id'] as String)) {
      return;
    }
    setState(() => _busy = true);
    try {
      final api = ref.read(apiProvider);
      if (isRole) {
        await api.rpc(enable ? 'grant_role' : 'revoke_role',
            {'p_employee_id': employee['id'], 'p_role': what, 'p_reason': reason});
      } else {
        await api.rpc('set_permission',
            {'p_employee_id': employee['id'], 'p_permission': what, 'p_enabled': enable, 'p_reason': reason});
      }
      ref.invalidate(accessGrantsProvider);
      if (mounted) showMessage(context, 'Access updated. It applies at their next action.');
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(accessGrantsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Roles & permissions')),
      body: PermissionGate(
        allowed: (s) => s.isAdmin,
        child: AsyncView(
          value: data,
          onRetry: () => ref.invalidate(accessGrantsProvider),
          builder: (rows) {
            final q = _query.toLowerCase();
            final filtered = rows.where((r) {
              final e = (r['employee'] as Map);
              return q.isEmpty || (e['name'] as String).toLowerCase().contains(q) ||
                  (e['code'] as String).toLowerCase().startsWith(q);
            }).toList();
            return ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
              SectionCard(
                color: AppColors.attendanceCard,
                child: Text('Manager: team reports and approvals. HR: employee records, policies, organisation reports and '
                    'approvals. Payroll and medical documents always need their own permission. Admin: everything. '
                    'A Manager role is also given automatically when someone is made a team manager.',
                    style: Theme.of(context).textTheme.bodyMedium),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Search people'),
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
              const SizedBox(height: AppSpacing.md),
              for (final r in filtered) _PersonAccess(row: r, busy: _busy, onChange: _change),
            ]);
          },
        ),
      ),
    );
  }
}

class _PersonAccess extends StatelessWidget {
  const _PersonAccess({required this.row, required this.busy, required this.onChange});
  final Map<String, dynamic> row;
  final bool busy;
  final Future<void> Function({
    required Map<String, dynamic> employee,
    required String what,
    required bool enable,
    required bool isRole,
  }) onChange;

  @override
  Widget build(BuildContext context) {
    final e = (row['employee'] as Map).cast<String, dynamic>();
    final roles = ((row['roles'] as List?) ?? const []).cast<String>();
    final perms = ((row['permissions'] as List?) ?? const []).cast<String>();
    final inactive = e['status'] != 'active';
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: ExpansionTile(
        shape: const Border(),
        title: Text('${e['name']}'),
        subtitle: Text([
          e['code'],
          roles.isEmpty ? 'Member' : roles.map(roleLabel).join(', '),
          if (perms.isNotEmpty) '+${perms.length} permission(s)',
          if (inactive) 'inactive',
        ].join(' · ')),
        childrenPadding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
        children: [
          Align(alignment: Alignment.centerLeft, child: Text('Roles', style: Theme.of(context).textTheme.bodySmall)),
          Wrap(spacing: AppSpacing.sm, children: [
            for (final role in const ['manager', 'hr', 'admin'])
              FilterChip(
                label: Text(roleLabel(role)),
                selected: roles.contains(role),
                onSelected: busy || inactive
                    ? null
                    : (on) => onChange(employee: e, what: role, enable: on, isRole: true),
              ),
          ]),
          const SizedBox(height: AppSpacing.sm),
          Align(alignment: Alignment.centerLeft, child: Text('Extra permissions', style: Theme.of(context).textTheme.bodySmall)),
          for (final p in _grantable)
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: perms.contains(p),
              title: Text(permissionLabel(p)),
              subtitle: _sensitive(p) ? const Text('Needs password confirmation') : null,
              onChanged: busy || inactive ? null : (on) => onChange(employee: e, what: p, enable: on, isRole: false),
            ),
        ],
      ),
    );
  }
}
