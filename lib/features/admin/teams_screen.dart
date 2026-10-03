import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/pickers.dart';
import '../../core/widgets/states.dart';
import '../people/people_screen.dart';

/// S29 — departments, teams and effective-dated team managers. The server
/// rejects reporting cycles and a manager inside their own team.
class TeamsScreen extends ConsumerStatefulWidget {
  const TeamsScreen({super.key, this.initialSection});

  final String? initialSection;

  @override
  ConsumerState<TeamsScreen> createState() => _TeamsScreenState();
}

class _TeamsScreenState extends ConsumerState<TeamsScreen> {
  bool _busy = false;
  bool _positionedInitialSection = false;
  final _departmentsKey = GlobalKey();

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(orgStructureProvider);
      if (mounted) showMessage(context, done);
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
      ref.invalidate(orgStructureProvider);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editDepartment(Map<String, dynamic>? d) async {
    final name = TextEditingController(text: d?['name'] as String?);
    var active = d?['active'] as bool? ?? true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            title: Text(d == null ? 'New department' : 'Edit department'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                if (d != null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active'),
                    value: active,
                    onChanged: (v) => setState(() => active = v),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    final text = name.text.trim();
    name.dispose();
    if (ok != true) return;
    await _run(
      () => ref.read(apiProvider).rpc('save_department', {
        'p_id': d?['id'],
        'p_name': text,
        'p_active': active,
        'p_expected_version': d?['version'],
      }),
      'Department saved.',
    );
  }

  Future<void> _editTeam(
    Map<String, dynamic>? t,
    List<Map<String, dynamic>> departments,
  ) async {
    final name = TextEditingController(text: t?['name'] as String?);
    String? dept = t?['department_id'] as String?;
    var active = t?['active'] as bool? ?? true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            title: Text(t == null ? 'New team' : 'Edit team'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String?>(
                  icon: const AppIcon(Icons.keyboard_arrow_down_rounded),
                  initialValue: dept,
                  decoration: const InputDecoration(labelText: 'Department'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('None')),
                    for (final d in departments)
                      DropdownMenuItem(
                        value: d['id'] as String,
                        child: Text(d['name'] as String),
                      ),
                  ],
                  onChanged: (v) => setState(() => dept = v),
                ),
                if (t != null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active'),
                    value: active,
                    onChanged: (v) => setState(() => active = v),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    final text = name.text.trim();
    name.dispose();
    if (ok != true) return;
    await _run(
      () => ref.read(apiProvider).rpc('save_team', {
        'p_id': t?['id'],
        'p_name': text,
        'p_department_id': dept,
        'p_active': active,
        'p_expected_version': t?['version'],
      }),
      'Team saved.',
    );
  }

  Future<void> _setManager(
    Map<String, dynamic> team, {
    required bool remove,
  }) async {
    Map<String, dynamic>? who;
    if (!remove) {
      who = await pickEmployee(context, title: 'Manager for ${team['name']}');
      if (who == null || !mounted) return;
    }
    DateTime from = OrgTime.today();
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            title: Text(
              remove
                  ? 'Remove manager of ${team['name']}?'
                  : '${who!['name']} manages ${team['name']}',
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DateField(
                  label: 'Effective from',
                  date: from,
                  onChanged: (d) => setState(() => from = d),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: reason,
                  maxLength: 500,
                  decoration: const InputDecoration(labelText: 'Reason'),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Pending requests keep their current approver. Reassign them from Review requests if needed.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    final why = reason.text.trim();
    reason.dispose();
    if (ok != true) return;
    await _run(
      () => ref.read(apiProvider).rpc('set_team_manager', {
        'p_team_id': team['id'],
        'p_manager_id': who?['id'],
        'p_effective_from': OrgTime.ymd(from),
        'p_reason': why.isEmpty ? null : why,
      }),
      'Manager updated.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(orgStructureProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Teams & departments')),
      body: PermissionGate(
        allowed: (s) => s.canMasterData,
        child: AsyncView(
          value: data,
          onRetry: () => ref.invalidate(orgStructureProvider),
          builder: (d) {
            final departments = structureList(d, 'departments');
            final teams = structureList(d, 'teams');
            if (widget.initialSection == 'departments' &&
                !_positionedInitialSection) {
              _positionedInitialSection = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final target = _departmentsKey.currentContext;
                if (target != null) {
                  Scrollable.ensureVisible(
                    target,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    alignment: 0.08,
                  );
                }
              });
            }
            String deptName(String? id) =>
                departments.where((x) => x['id'] == id).firstOrNull?['name']
                    as String? ??
                '—';
            return RefreshIndicator(
              onRefresh: () => ref.refresh(orgStructureProvider.future),
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.page),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Teams',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _editTeam(null, departments),
                        icon: const AppIcon(Icons.add_rounded),
                        label: const Text('Team'),
                      ),
                    ],
                  ),
                  if (teams.isEmpty)
                    const EmptyState(
                      icon: Icons.groups_outlined,
                      title: 'No teams yet',
                    ),
                  for (final t in teams)
                    Card(
                      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    t['name'] as String,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall,
                                  ),
                                ),
                                if (t['active'] != true)
                                  const StatusChip(
                                    'Inactive',
                                    tone: ChipTone.neutral,
                                  ),
                                IconButton(
                                  tooltip: 'Edit team',
                                  onPressed: _busy
                                      ? null
                                      : () => _editTeam(t, departments),
                                  icon: const AppIcon(Icons.edit_outlined),
                                ),
                              ],
                            ),
                            Text(
                              '${deptName(t['department_id'] as String?)} · ${t['member_count']} member(s)',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Row(
                              children: [
                                const AppIcon(
                                  Icons.supervisor_account_outlined,
                                  size: 18,
                                  color: AppColors.textSecondary,
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                Expanded(
                                  child: Text(
                                    t['manager'] == null
                                        ? 'No manager'
                                        : '${(t['manager'] as Map)['name']} since '
                                              '${OrgTime.date((t['manager'] as Map)['since'] as String?, pattern: 'd MMM yyyy')}',
                                  ),
                                ),
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _setManager(t, remove: false),
                                  child: Text(
                                    t['manager'] == null ? 'Set' : 'Change',
                                  ),
                                ),
                                if (t['manager'] != null)
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _setManager(t, remove: true),
                                    child: const Text('Remove'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: AppSpacing.xl),
                  Row(
                    key: _departmentsKey,
                    children: [
                      Expanded(
                        child: Text(
                          'Departments',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _busy ? null : () => _editDepartment(null),
                        icon: const AppIcon(Icons.add_rounded),
                        label: const Text('Department'),
                      ),
                    ],
                  ),
                  for (final dep in departments)
                    Card(
                      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: ListTile(
                        title: Text(dep['name'] as String),
                        subtitle: dep['active'] == true
                            ? null
                            : const Text('Inactive'),
                        trailing: const AppIcon(Icons.edit_outlined),
                        onTap: _busy ? null : () => _editDepartment(dep),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
