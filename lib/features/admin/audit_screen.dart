import '../../core/widgets/app_icon.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/paged_list.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/pickers.dart';
import '../../core/widgets/states.dart';
import '../people/people_screen.dart';

const _areas = [
  ('auth.', 'Sign-in & passwords'),
  ('credentials.', 'Password resets'),
  ('employee.', 'Employees'),
  ('role.', 'Roles'),
  ('permission.', 'Permissions'),
  ('attendance.', 'Attendance'),
  ('request.', 'Requests & approvals'),
  ('leave', 'Leave'),
  ('payslip.', 'Payslips'),
  ('file.', 'File access'),
  ('archive.', 'Archive & cleanup'),
  ('holiday.', 'Holidays'),
  ('shift.', 'Shifts'),
  ('office.', 'Offices'),
  ('org.', 'Organisation'),
];

/// S36 — audit history. Admin sees everything; HR with scoped audit sees
/// business events about non-Admin employees only (server-filtered). Values
/// are already redacted server-side (no passwords, tokens or links).
class AuditScreen extends ConsumerStatefulWidget {
  const AuditScreen({super.key});

  @override
  ConsumerState<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends ConsumerState<AuditScreen> {
  String? _area;
  Map<String, dynamic>? _actor;
  Map<String, dynamic>? _target;
  DateTimeRange? _range;

  @override
  Widget build(BuildContext context) {
    final api = ref.read(apiProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Audit history')),
      body: PermissionGate(
        allowed: (s) => s.canAudit,
        child: Column(children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(AppSpacing.page),
            child: Row(children: [
              FilterMenu(
                label: 'Area',
                value: _area,
                options: [for (final a in _areas) (a.$1, a.$2)],
                onChanged: (v) => setState(() => _area = v),
              ),
              const SizedBox(width: AppSpacing.sm),
              InputChip(
                avatar: const AppIcon(Icons.date_range_rounded, size: 18),
                label: Text(_range == null
                    ? 'Any date'
                    : '${OrgTime.ymd(_range!.start)} – ${OrgTime.ymd(_range!.end)}'),
                onPressed: () async {
                  final today = OrgTime.today();
                  final r = await showDateRangePicker(
                      context: context, firstDate: DateTime(today.year - 5), lastDate: today, initialDateRange: _range);
                  setState(() => _range = r);
                },
                onDeleted: _range == null ? null : () => setState(() => _range = null),
              ),
              const SizedBox(width: AppSpacing.sm),
              InputChip(
                avatar: const AppIcon(Icons.person_outline_rounded, size: 18),
                label: Text(_actor == null ? 'Any actor' : 'By ${_actor!['name']}'),
                onPressed: () async {
                  final p = await pickEmployee(context, title: 'Actor', status: 'all');
                  if (p != null) setState(() => _actor = p);
                },
                onDeleted: _actor == null ? null : () => setState(() => _actor = null),
              ),
              const SizedBox(width: AppSpacing.sm),
              InputChip(
                avatar: const AppIcon(Icons.badge_outlined, size: 18),
                label: Text(_target == null ? 'Any employee' : 'About ${_target!['name']}'),
                onPressed: () async {
                  final p = await pickEmployee(context, title: 'About employee', status: 'all');
                  if (p != null) setState(() => _target = p);
                },
                onDeleted: _target == null ? null : () => setState(() => _target = null),
              ),
            ]),
          ),
          Expanded(
            child: PagedList<Map<String, dynamic>>(
              key: ValueKey('$_area|${_actor?['id']}|${_target?['id']}|$_range'),
              fetch: (cursor) async {
                final c = cursor as (String, int)?;
                final rows = (await api.rpc('list_audit', {
                  'p_from': _range == null ? null : OrgTime.atLocal(_range!.start, 0, 0).toIso8601String(),
                  'p_to': _range == null ? null : OrgTime.atLocal(_range!.end, 0, 0, addDays: 1).toIso8601String(),
                  'p_actor_id': _actor?['id'],
                  'p_action_prefix': _area,
                  'p_target_employee_id': _target?['id'],
                  'p_before_created_at': c?.$1,
                  'p_before_id': c?.$2,
                  'p_limit': 50,
                }))
                    .list;
                return PageResult(rows,
                    next: rows.length < 50 ? null : (rows.last['created_at'] as String, (rows.last['id'] as num).toInt()));
              },
              empty: const EmptyState(icon: Icons.history_rounded, title: 'No matching events'),
              itemBuilder: (context, a) => _AuditTile(a: a),
            ),
          ),
        ]),
      ),
    );
  }
}

class _AuditTile extends StatelessWidget {
  const _AuditTile({required this.a});
  final Map<String, dynamic> a;

  @override
  Widget build(BuildContext context) {
    final actor = (a['actor'] as Map?)?['name'] as String?;
    final target = (a['target_employee'] as Map?)?['name'] as String?;
    final changes = a['changes'];
    return Card(
      child: ExpansionTile(
        shape: const Border(),
        title: Text(a['action'] as String? ?? '', style: const TextStyle(fontFamily: 'monospace', fontSize: 14)),
        subtitle: Text([
          actor ?? 'System',
          if (target != null) 'about $target',
          OrgTime.dateTime(a['created_at']),
        ].join(' · ')),
        childrenPadding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
        children: [
          KeyValueRow('Type', '${a['classification']} · ${a['target_type'] ?? '—'}'),
          if (a['request_id'] != null) KeyValueRow('Request ID', (a['request_id'] as String).substring(0, 8)),
          if (changes != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(8)),
              child: SelectableText(const JsonEncoder.withIndent('  ').convert(changes),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
