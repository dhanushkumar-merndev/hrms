import '../../core/widgets/app_icon.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/auth/session_controller.dart';
import '../../core/format.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/paged_list.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/states.dart';
import '../people/people_screen.dart';

/// S25 — HR/Admin employee list with search, status/team filters and the
/// active-employee cap.
class EmployeesScreen extends ConsumerStatefulWidget {
  const EmployeesScreen({super.key});

  @override
  ConsumerState<EmployeesScreen> createState() => _EmployeesScreenState();
}

class _EmployeesScreenState extends ConsumerState<EmployeesScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  String _status = 'active';
  String? _teamId;
  int _generation = 0;
  (int, int)? _cap;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionContextProvider);
    final teams = structureList(ref.watch(orgStructureProvider).value, 'teams');
    final api = ref.read(apiProvider);
    final cap = _cap;
    return Scaffold(
      appBar: AppBar(title: const Text('Employees'), actions: [
        if ((session?.canProvision ?? false) || (session?.canManagePayroll ?? false))
          IconButton(
            tooltip: 'Import from Excel',
            icon: const AppIcon(Icons.upload_file_rounded),
            onPressed: () => context.push('/employees/import').then((_) => setState(() => _generation++)),
          ),
      ]),
      floatingActionButton: (session?.canProvision ?? false)
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/employees/new').then((_) => setState(() => _generation++)),
              icon: const AppIcon(Icons.person_add_alt_1_rounded),
              label: const Text('Add employee'),
            )
          : null,
      body: PermissionGate(
        allowed: (s) => s.canViewEmployees,
        child: Column(children: [
          const OfflineBanner(),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.sm, AppSpacing.page, 0),
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(prefixIcon: AppIcon(Icons.search_rounded), hintText: 'Search name or employee ID'),
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), () => setState(() => _query = v.trim()));
              },
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page, vertical: AppSpacing.sm),
            child: Row(children: [
              for (final s in const [('active', 'Active'), ('inactive', 'Inactive'), ('pending', 'Setup pending'), ('all', 'All')]) ...[
                ChoiceChip(label: Text(s.$2), selected: _status == s.$1, onSelected: (_) => setState(() => _status = s.$1)),
                const SizedBox(width: AppSpacing.sm),
              ],
              FilterMenu(
                label: 'Team',
                value: _teamId,
                options: [for (final t in teams) (t['id'] as String, t['name'] as String)],
                onChanged: (v) => setState(() => _teamId = v),
              ),
            ]),
          ),
          if (cap != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
              child: Row(children: [
                AppIcon(Icons.groups_2_outlined, size: 18, color: cap.$1 >= cap.$2 ? AppColors.error : AppColors.textSecondary),
                const SizedBox(width: AppSpacing.sm),
                Text('${cap.$1} of ${cap.$2} active employees',
                    style: TextStyle(color: cap.$1 >= cap.$2 ? AppColors.error : AppColors.textSecondary)),
              ]),
            ),
          Expanded(
            child: PagedList<Map<String, dynamic>>(
              key: ValueKey('$_query|$_status|$_teamId|$_generation'),
              fetch: (cursor) async {
                final offset = (cursor as int?) ?? 0;
                final res = (await api.rpc('list_employees', {
                  'p_search': _query.isEmpty ? null : _query,
                  'p_status': _status,
                  'p_team_id': _teamId,
                  'p_limit': 30,
                  'p_offset': offset,
                }))
                    .map;
                final next = ((res['active_count'] as num?)?.toInt() ?? 0, (res['active_cap'] as num?)?.toInt() ?? 0);
                if (next != _cap) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _cap = next);
                  });
                }
                return offsetPage(res, offset);
              },
              empty: const EmptyState(icon: Icons.person_search_outlined, title: 'No employees match'),
              loading: const PeopleSkeleton(),
              itemBuilder: (context, e) {
                final roles = ((e['roles'] as List?) ?? const []).cast<String>();
                return PersonTile(
                  p: e,
                  onTap: () => context.push('/employees/${e['id']}').then((_) => setState(() => _generation++)),
                  trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    for (final r in roles.take(2)) StatusChip(roleLabel(r), tone: ChipTone.info),
                    if (e['status'] == 'inactive') const StatusChip('Inactive', tone: ChipTone.neutral),
                    if (e['setup_pending'] == true && e['status'] == 'active')
                      const StatusChip('First sign-in pending', tone: ChipTone.warning),
                  ]),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}
