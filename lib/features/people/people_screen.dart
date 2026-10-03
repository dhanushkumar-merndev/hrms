import '../../core/widgets/app_icon.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/format.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/paged_list.dart';
import '../../core/widgets/states.dart';
import '../home/home_providers.dart';

/// Teams, departments, offices and shifts (names only) for filters/pickers.
final orgStructureProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  cacheFor(ref, const Duration(minutes: 5));
  return (await ref.read(apiProvider).rpc('list_org_structure')).map;
});

List<Map<String, dynamic>> structureList(Map<String, dynamic>? s, String key) =>
    ((s?[key] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();

/// S17 — safe directory: name, code, designation, department, team and
/// business contact only. Private details are never sent to this view.
class PeopleScreen extends ConsumerStatefulWidget {
  const PeopleScreen({super.key});

  @override
  ConsumerState<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends ConsumerState<PeopleScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  String? _teamId;
  String? _departmentId;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final structure = ref.watch(orgStructureProvider).value;
    final teams = structureList(structure, 'teams').where((t) => t['active'] == true).toList();
    final departments = structureList(structure, 'departments').where((d) => d['active'] == true).toList();
    final api = ref.read(apiProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('My workmates')),
      body: Column(children: [
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
            FilterMenu(
              label: 'Team',
              value: _teamId,
              options: [for (final t in teams) (t['id'] as String, t['name'] as String)],
              onChanged: (v) => setState(() => _teamId = v),
            ),
            const SizedBox(width: AppSpacing.sm),
            FilterMenu(
              label: 'Department',
              value: _departmentId,
              options: [for (final d in departments) (d['id'] as String, d['name'] as String)],
              onChanged: (v) => setState(() => _departmentId = v),
            ),
          ]),
        ),
        Expanded(
          child: PagedList<Map<String, dynamic>>(
            key: ValueKey('$_query|$_teamId|$_departmentId'),
            fetch: (cursor) async {
              final offset = (cursor as int?) ?? 0;
              final res = await api.rpc('list_directory', {
                'p_search': _query.isEmpty ? null : _query,
                'p_team_id': _teamId,
                'p_department_id': _departmentId,
                'p_limit': 30,
                'p_offset': offset,
              });
              return offsetPage(res.map, offset);
            },
            empty: const EmptyState(icon: Icons.person_search_outlined, title: 'No one matches'),
            loading: const PeopleSkeleton(),
            itemBuilder: (context, p) => PersonTile(p: p, onTap: () => _showPerson(context, p)),
          ),
        ),
      ]),
    );
  }

  void _showPerson(BuildContext context, Map<String, dynamic> p) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: AppColors.peopleCard,
              child: Text(
                initialsOf(p['name'] as String?),
                style: const TextStyle(color: AppColors.peopleAction, fontWeight: FontWeight.w700, fontSize: 18),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p['name'] as String? ?? '', style: Theme.of(ctx).textTheme.titleLarge),
                Text('${p['code']}${p['designation'] != null ? ' · ${p['designation']}' : ''}',
                    style: Theme.of(ctx).textTheme.bodyMedium),
              ]),
            ),
          ]),
          const SizedBox(height: AppSpacing.lg),
          KeyValueRow('Department', ((p['department'] as Map?)?['name'] as String?) ?? '—'),
          KeyValueRow('Team', ((p['team'] as Map?)?['name'] as String?) ?? '—'),
          for (final (label, key) in const [('Work email', 'business_email'), ('Work phone', 'business_phone')])
            if (p[key] != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(label, style: Theme.of(ctx).textTheme.bodyMedium),
                subtitle: Text(p[key] as String, style: Theme.of(ctx).textTheme.bodyLarge),
                trailing: IconButton(
                  tooltip: 'Copy $label',
                  icon: const AppIcon(Icons.copy_rounded),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: p[key] as String));
                    Navigator.pop(ctx);
                    showMessage(context, '$label copied.');
                  },
                ),
              ),
        ]),
      ),
    );
  }
}

class PersonTile extends StatelessWidget {
  const PersonTile({super.key, required this.p, this.onTap, this.trailing});
  final Map<String, dynamic> p;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final team = (p['team'] as Map?)?['name'] as String?;
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: AppColors.peopleCard,
              child: Text(initialsOf(p['name'] as String?),
                  style: const TextStyle(color: AppColors.peopleAction, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p['name'] as String? ?? '', style: Theme.of(context).textTheme.titleSmall,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                Text([p['code'], p['designation'], team].whereType<String>().join(' · '),
                    style: Theme.of(context).textTheme.bodyMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
              ]),
            ),
            ?trailing,
          ]),
        ),
      ),
    );
  }
}

/// Filter chip menu (also used by report and employee screens).
class FilterMenu extends StatelessWidget {
  const FilterMenu({super.key, required this.label, required this.value, required this.options, required this.onChanged});
  final String label;
  final String? value;
  final List<(String, String)> options;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = options.where((o) => o.$1 == value).firstOrNull;
    return PopupMenuButton<String?>(
      tooltip: 'Filter by $label',
      onSelected: (v) => onChanged(v == '' ? null : v),
      itemBuilder: (_) => [
        PopupMenuItem(value: '', child: Text('All ${label.toLowerCase()}s')),
        for (final o in options) PopupMenuItem(value: o.$1, child: Text(o.$2)),
      ],
      child: Chip(
        avatar: const AppIcon(Icons.filter_list_rounded, size: 18),
        label: Text(selected == null ? label : '$label: ${selected.$2}'),
      ),
    );
  }
}
