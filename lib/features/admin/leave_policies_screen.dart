import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/auth/session_controller.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/pickers.dart';
import '../../core/widgets/states.dart';
import '../../core/widgets/pill_tabs.dart';
import '../leave/leave_apply_screen.dart';
import '../leave/leave_screen.dart';
import '../people/people_screen.dart';

final _typesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  return (await ref.read(apiProvider).rpc('list_leave_types', {'p_include_inactive': true})).list;
});
final _policiesProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, int?>((ref, year) async {
  return (await ref.read(apiProvider).rpc('list_leave_policies', {'p_leave_year': year})).map;
});
final _routesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  return (await ref.read(apiProvider).rpc('list_approval_routes')).list;
});
final _adminHolidaysProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, int>((ref, year) async {
  return (await ref.read(apiProvider).rpc('list_holidays', {'p_year': year, 'p_office_id': null})).map;
});
final _suggestionsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return (await ref.read(apiProvider).rpc('list_holiday_suggestions', {'p_year': null})).map;
});

Future<void> _run(BuildContext context, Future<void> Function() action, {String? done}) async {
  try {
    await action();
    if (context.mounted && done != null) showMessage(context, done);
  } on ApiException catch (e) {
    if (context.mounted) showMessage(context, e.message, error: true);
  }
}

/// S32 — leave types, yearly entitlements, approval routes and the holiday
/// calendar. Paid-leave entitlement and company holidays are separate:
/// "12 holidays" never means "12 paid leave days".
class LeavePoliciesScreen extends ConsumerWidget {
  const LeavePoliciesScreen({super.key, this.initialTab});
  final String? initialTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(sessionContextProvider)?.isAdmin ?? false;
    final tabs = ['types', 'entitlements', if (isAdmin) 'approvals', 'holidays'];
    final initial = tabs.indexOf(initialTab ?? '').clamp(0, tabs.length - 1);
    return DefaultTabController(
      length: tabs.length,
      initialIndex: initial,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Leave & holidays'),
          bottom: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              tabs: [
            const Tab(text: 'Leave types'),
            const Tab(text: 'Entitlements'),
            if (isAdmin) const Tab(text: 'Approvals'),
            const Tab(text: 'Holidays'),
          ]),
        ),
        body: PermissionGate(
          allowed: (s) => s.canDraftPolicy,
          child: TabBarView(children: [
            _TypesTab(isAdmin: isAdmin),
            _EntitlementsTab(isAdmin: isAdmin),
            if (isAdmin) const _RoutesTab(),
            _HolidaysTab(isAdmin: isAdmin),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- types

class _TypesTab extends ConsumerWidget {
  const _TypesTab({required this.isAdmin});
  final bool isAdmin;

  Future<void> _edit(BuildContext context, WidgetRef ref, Map<String, dynamic>? t) async {
    final code = TextEditingController(text: t?['code'] as String?);
    final name = TextEditingController(text: t?['name'] as String?);
    final maxDays = TextEditingController(text: t?['max_consecutive_days']?.toString());
    final notice = TextEditingController(text: '${t?['advance_notice_days'] ?? 0}');
    final backdate = TextEditingController(text: '${t?['backdate_days'] ?? 7}');
    var paid = t?['paid'] as bool? ?? true;
    var half = t?['half_day_allowed'] as bool? ?? true;
    var attach = t?['requires_attachment'] as bool? ?? false;
    var medical = t?['attachment_class'] == 'medical';
    var active = t?['active'] as bool? ?? true;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(AppSpacing.page), children: [
            Text(t == null ? 'New leave type' : 'Edit ${t['name']}', style: Theme.of(ctx).textTheme.titleMedium),
            TextField(controller: code, enabled: t == null, textCapitalization: TextCapitalization.characters,
                maxLength: 16, decoration: const InputDecoration(labelText: 'Code (e.g. CL)')),
            TextField(controller: name, maxLength: 60, decoration: const InputDecoration(labelText: 'Name')),
            SwitchListTile(contentPadding: EdgeInsets.zero, value: paid, title: const Text('Paid (uses balance)'),
                onChanged: (v) => setState(() => paid = v)),
            SwitchListTile(contentPadding: EdgeInsets.zero, value: half, title: const Text('Half days allowed'),
                onChanged: (v) => setState(() => half = v)),
            SwitchListTile(contentPadding: EdgeInsets.zero, value: attach, title: const Text('Supporting document required'),
                onChanged: (v) => setState(() => attach = v)),
            SwitchListTile(contentPadding: EdgeInsets.zero, value: medical, title: const Text('Documents are medical'),
                subtitle: const Text('Only reviewers with the medical permission can open them.'),
                onChanged: (v) => setState(() => medical = v)),
            TextField(controller: maxDays, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Max consecutive days (optional)')),
            TextField(controller: notice, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Apply at least N days in advance')),
            TextField(controller: backdate, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Can be backdated up to N days')),
            if (t != null)
              SwitchListTile(contentPadding: EdgeInsets.zero, value: active, title: const Text('Active'),
                  onChanged: (v) => setState(() => active = v)),
            const SizedBox(height: AppSpacing.md),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ]),
        );
      }),
    );
    final values = (code.text.trim().toUpperCase(), name.text.trim(), int.tryParse(maxDays.text.trim()),
        int.tryParse(notice.text.trim()) ?? 0, int.tryParse(backdate.text.trim()) ?? 7);
    for (final c in [code, name, maxDays, notice, backdate]) {
      c.dispose();
    }
    if (ok != true || !context.mounted) return;
    await _run(context, () async {
      await ref.read(apiProvider).rpc('save_leave_type', {
        'p_id': t?['id'],
        'p_code': values.$1,
        'p_name': values.$2,
        'p_paid': paid,
        'p_half_day_allowed': half,
        'p_requires_attachment': attach,
        'p_attachment_class': medical ? 'medical' : 'general',
        'p_max_consecutive_days': values.$3,
        'p_advance_notice_days': values.$4,
        'p_backdate_days': values.$5,
        'p_active': active,
        'p_expected_version': t?['version'],
      });
      ref.invalidate(_typesProvider);
      ref.invalidate(leaveTypesProvider);
    }, done: 'Leave type saved.');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_typesProvider);
    return AsyncView(
      value: data,
      onRetry: () => ref.invalidate(_typesProvider),
      builder: (rows) => ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
        if (isAdmin)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(onPressed: () => _edit(context, ref, null), icon: const Icon(Icons.add_rounded),
                label: const Text('Leave type')),
          ),
        if (rows.isEmpty)
          const EmptyState(icon: Icons.beach_access_outlined, title: 'No leave types yet',
              message: 'Add types such as Casual, Sick and Unpaid, then set each year\'s entitlement.'),
        for (final t in rows)
          Card(
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: ListTile(
              title: Text('${t['name']} (${t['code']})'),
              subtitle: Text([
                t['paid'] == true ? 'Paid' : 'Unpaid',
                t['half_day_allowed'] == true ? 'half days' : 'full days only',
                if (t['requires_attachment'] == true) '${t['attachment_class'] == 'medical' ? 'medical ' : ''}document required',
                if (t['max_consecutive_days'] != null) 'max ${t['max_consecutive_days']} days',
                'backdate ${t['backdate_days']} d',
                if ((t['advance_notice_days'] as num? ?? 0) > 0) 'notice ${t['advance_notice_days']} d',
                if (t['active'] != true) 'inactive',
              ].join(' · ')),
              trailing: isAdmin ? const Icon(Icons.edit_outlined) : null,
              onTap: isAdmin ? () => _edit(context, ref, t) : null,
            ),
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- entitlements

class _EntitlementsTab extends ConsumerStatefulWidget {
  const _EntitlementsTab({required this.isAdmin});
  final bool isAdmin;

  @override
  ConsumerState<_EntitlementsTab> createState() => _EntitlementsTabState();
}

class _EntitlementsTabState extends ConsumerState<_EntitlementsTab> {
  int? _year;

  Future<void> _edit(Map<String, dynamic> type, Map<String, dynamic>? policy, int year) async {
    final days = TextEditingController(text: policy == null ? '' : daysFromUnits(policy['annual_units'] as num?));
    final carry = TextEditingController(text: policy == null ? '0' : daysFromUnits(policy['carry_cap_units'] as num?));
    final expiry = TextEditingController(text: policy?['carry_expiry_months']?.toString() ?? '');
    var prorata = policy?['prorata'] == true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
        return AlertDialog(
          title: Text('${type['name']} · leave year $year'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: days, keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Days per year', helperText: 'Half days allowed, e.g. 12 or 7.5')),
              const SizedBox(height: AppSpacing.md),
              TextField(controller: carry, keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Carry forward at most (days)')),
              const SizedBox(height: AppSpacing.md),
              TextField(controller: expiry, keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Carried days expire after (months, optional)')),
              SwitchListTile(contentPadding: EdgeInsets.zero, value: prorata, title: const Text('Pro-rata for mid-year joiners'),
                  onChanged: (v) => setState(() => prorata = v)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save draft')),
          ],
        );
      }),
    );
    final d = double.tryParse(days.text.trim());
    final c = double.tryParse(carry.text.trim()) ?? 0;
    final e = int.tryParse(expiry.text.trim());
    for (final x in [days, carry, expiry]) {
      x.dispose();
    }
    if (ok != true || !mounted) return;
    if (d == null || (d * 2) != (d * 2).roundToDouble() || (c * 2) != (c * 2).roundToDouble()) {
      showMessage(context, 'Use whole or half days.', error: true);
      return;
    }
    await _run(context, () async {
      await ref.read(apiProvider).rpc('save_leave_policy', {
        'p_leave_type_id': type['id'],
        'p_leave_year': year,
        'p_annual_units': (d * 2).round(),
        'p_carry_cap_units': (c * 2).round(),
        'p_carry_expiry_months': e,
        'p_prorata': prorata,
      });
      ref.invalidate(_policiesProvider);
    }, done: 'Draft saved.');
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(_policiesProvider(_year));
    final types = ref.watch(_typesProvider).value ?? const [];
    return AsyncView(
      value: data,
      onRetry: () => ref.invalidate(_policiesProvider(_year)),
      builder: (d) {
        final year = (d['leave_year'] as num).toInt();
        final policies = ((d['policies'] as List?) ?? const []).map((p) => (p as Map).cast<String, dynamic>()).toList();
        final paidTypes = types.where((t) => t['paid'] == true && t['active'] == true).toList();
        return ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
          Row(children: [
            IconButton(tooltip: 'Previous year', onPressed: () => setState(() => _year = year - 1),
                icon: const Icon(Icons.chevron_left_rounded)),
            Expanded(child: Text('Leave year $year', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium)),
            IconButton(tooltip: 'Next year', onPressed: () => setState(() => _year = year + 1),
                icon: const Icon(Icons.chevron_right_rounded)),
          ]),
          SectionCard(
            color: AppColors.leaveCard,
            child: Text('Publishing allocates the yearly days to every active employee once and moves capped carry-forward '
                'from the previous year exactly once. New joiners receive published entitlements automatically. '
                'Company holidays are managed separately.', style: Theme.of(context).textTheme.bodyMedium),
          ),
          const SizedBox(height: AppSpacing.md),
          if (paidTypes.isEmpty) const EmptyState(icon: Icons.beach_access_outlined, title: 'Add a paid leave type first'),
          for (final t in paidTypes)
            Builder(builder: (context) {
              final p = policies.where((x) => (x['leave_type'] as Map)['id'] == t['id']).firstOrNull;
              final published = p?['state'] == 'published';
              return Card(
                margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(t['name'] as String, style: Theme.of(context).textTheme.titleSmall)),
                      StatusChip(p == null ? 'Not set' : published ? 'Published' : 'Draft',
                          tone: p == null ? ChipTone.neutral : published ? ChipTone.success : ChipTone.warning),
                    ]),
                    if (p != null)
                      Text('${daysFromUnits(p['annual_units'] as num?)} days/year · carry up to '
                          '${daysFromUnits(p['carry_cap_units'] as num?)} days'
                          '${p['carry_expiry_months'] != null ? ', expiring after ${p['carry_expiry_months']} months' : ''}'
                          '${p['prorata'] == true ? ' · pro-rata' : ''}'),
                    if (!published)
                      Wrap(spacing: AppSpacing.sm, children: [
                        TextButton(onPressed: () => _edit(t, p, year), child: Text(p == null ? 'Set entitlement' : 'Edit draft')),
                        if (p != null && widget.isAdmin)
                          FilledButton(
                            onPressed: () async {
                              final ok = await confirm(context,
                                  title: 'Publish ${t['name']} for $year?',
                                  message: 'Every active employee receives ${daysFromUnits(p['annual_units'] as num?)} days '
                                      'for leave year $year. This cannot be edited afterwards; use balance adjustments '
                                      'for individual corrections.',
                                  confirmLabel: 'Publish');
                              if (!ok || !context.mounted) return;
                              await _run(context, () async {
                                await ref.read(apiProvider).rpc('publish_leave_policy', {'p_policy_id': p['id']});
                                ref.invalidate(_policiesProvider);
                                ref.invalidate(leaveBalancesProvider);
                              }, done: 'Published.');
                            },
                            child: const Text('Publish'),
                          ),
                      ]),
                  ]),
                ),
              );
            }),
        ]);
      },
    );
  }
}

// ---------------------------------------------------------------- approval routes

class _RoutesTab extends ConsumerWidget {
  const _RoutesTab();

  Future<void> _edit(BuildContext context, WidgetRef ref, Map<String, dynamic> team, Map<String, dynamic> route) async {
    var mode = (route['mode'] as String?) ?? 'manager';
    Map<String, dynamic>? hr = (route['hr_reviewer'] as Map?)?.cast<String, dynamic>();
    Map<String, dynamic>? fallback = (route['fallback'] as Map?)?.cast<String, dynamic>();
    final reason = TextEditingController();
    final kind = route['kind'] == 'leave' ? 'leave' : 'attendance correction';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
        return AlertDialog(
          title: Text('${team['name']}: $kind'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              PillTabs<String>(
                options: const [('manager', 'Team manager'), ('hr', 'HR person')],
                value: mode,
                onChanged: (v) => setState(() => mode = v),
              ),
              const SizedBox(height: AppSpacing.md),
              if (mode == 'hr')
                PickerField(
                  label: 'HR approver',
                  value: hr == null ? null : '${hr!['name']} (${hr!['code']})',
                  onTap: () async {
                    final p = await pickEmployee(ctx, title: 'HR approver', source: 'reviewers');
                    if (p != null) setState(() => hr = p);
                  },
                ),
              const SizedBox(height: AppSpacing.md),
              PickerField(
                label: 'Fallback approver',
                value: fallback == null ? null : '${fallback!['name']} (${fallback!['code']})',
                onTap: () async {
                  final p = await pickEmployee(ctx, title: 'Fallback approver', source: 'reviewers');
                  if (p != null) setState(() => fallback = p);
                },
              ),
              const SizedBox(height: AppSpacing.xs),
              Text('Used when the main approver is the requester or unavailable. Nobody approves their own request.',
                  style: Theme.of(ctx).textTheme.bodySmall),
              TextField(controller: reason, maxLength: 500, decoration: const InputDecoration(labelText: 'Reason')),
              Text('Requests already submitted keep their current approver.', style: Theme.of(ctx).textTheme.bodySmall),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        );
      }),
    );
    final why = reason.text.trim();
    reason.dispose();
    if (ok != true || !context.mounted) return;
    await _run(context, () async {
      await ref.read(apiProvider).rpc('set_approval_route', {
        'p_team_id': team['id'],
        'p_kind': route['kind'],
        'p_mode': mode,
        'p_hr_reviewer_id': mode == 'hr' ? (hr?['id']) : null,
        'p_fallback_reviewer_id': fallback?['id'],
        'p_reason': why.isEmpty ? null : why,
      });
      ref.invalidate(_routesProvider);
    }, done: 'Approval route saved.');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_routesProvider);
    return AsyncView(
      value: data,
      onRetry: () => ref.invalidate(_routesProvider),
      isEmpty: (rows) => rows.isEmpty,
      empty: const EmptyState(icon: Icons.alt_route_rounded, title: 'Create teams first'),
      builder: (rows) => ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
        for (final t in rows)
          Card(
            margin: const EdgeInsets.only(bottom: AppSpacing.md),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text((t['team'] as Map)['name'] as String, style: Theme.of(context).textTheme.titleSmall),
                for (final r in ((t['routes'] as List?) ?? const []).map((x) => (x as Map).cast<String, dynamic>()))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(r['kind'] == 'leave' ? 'Leave' : 'Attendance corrections'),
                    subtitle: Text(r['route_id'] == null
                        ? 'Not set — requests will wait for an approver'
                        : [
                            r['mode'] == 'hr' ? 'HR: ${(r['hr_reviewer'] as Map?)?['name'] ?? '—'}' : 'Team manager',
                            'fallback: ${(r['fallback'] as Map?)?['name'] ?? 'none'}',
                          ].join(' · ')),
                    trailing: r['route_id'] == null
                        ? const Icon(Icons.warning_amber_rounded, color: AppColors.warning)
                        : const Icon(Icons.edit_outlined),
                    onTap: () => _edit(context, ref, (t['team'] as Map).cast<String, dynamic>(), r),
                  ),
              ]),
            ),
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- holidays

class _HolidaysTab extends ConsumerStatefulWidget {
  const _HolidaysTab({required this.isAdmin});
  final bool isAdmin;

  @override
  ConsumerState<_HolidaysTab> createState() => _HolidaysTabState();
}

class _HolidaysTabState extends ConsumerState<_HolidaysTab> {
  late int _year = OrgTime.today().year;
  final _selected = <String>{};
  bool _refreshing = false;

  void _reload() {
    ref.invalidate(_adminHolidaysProvider);
    ref.invalidate(holidaysProvider);
    ref.invalidate(_suggestionsProvider);
  }

  Future<void> _edit(Map<String, dynamic>? h) async {
    final offices = structureList(ref.read(orgStructureProvider).value, 'offices');
    final name = TextEditingController(text: h?['name'] as String?);
    DateTime? date = h == null ? null : DateTime.tryParse(h['date'] as String);
    String? office = h?['office_id'] as String?;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
        return AlertDialog(
          title: Text(h == null ? 'Add holiday (draft)' : 'Edit draft holiday'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DateField(label: 'Date', date: date, first: OrgTime.today().add(const Duration(days: 1)),
                onChanged: (d) => setState(() => date = d)),
            const SizedBox(height: AppSpacing.md),
            TextField(controller: name, maxLength: 120, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: AppSpacing.sm),
            DropdownButtonFormField<String?>(
              initialValue: office,
              decoration: const InputDecoration(labelText: 'Applies to'),
              items: [
                const DropdownMenuItem(value: null, child: Text('All offices')),
                for (final o in offices) DropdownMenuItem(value: o['id'] as String, child: Text(o['name'] as String)),
              ],
              onChanged: (v) => setState(() => office = v),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save draft')),
          ],
        );
      }),
    );
    final text = name.text.trim();
    name.dispose();
    if (ok != true || !mounted || date == null) return;
    await _run(context, () async {
      await ref.read(apiProvider).rpc('save_holiday', {
        'p_id': h?['id'],
        'p_date': OrgTime.ymd(date!),
        'p_name': text,
        'p_office_id': office,
        'p_expected_version': h?['version'],
      });
      _reload();
    }, done: 'Draft saved.');
  }

  Future<void> _refreshSuggestions() async {
    setState(() => _refreshing = true);
    await _run(context, () async {
      final res = (await ref.read(apiProvider).function('holiday-suggestions', {})).map;
      ref.invalidate(_suggestionsProvider);
      if (mounted) showMessage(context, '${res['added']} new suggestion(s) from the public calendar.');
    });
    if (mounted) setState(() => _refreshing = false);
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(_adminHolidaysProvider(_year));
    final suggestions = ref.watch(_suggestionsProvider);
    return AsyncView(
      value: data,
      onRetry: () => ref.invalidate(_adminHolidaysProvider(_year)),
      builder: (d) {
        final list = ((d['holidays'] as List?) ?? const []).map((x) => (x as Map).cast<String, dynamic>()).toList();
        final published = list.where((h) => h['state'] == 'published').length;
        final target = (d['target'] as num?)?.toInt() ?? 12;
        final today = OrgTime.today();
        final selectable = _selected.where((id) => list.any((h) => h['id'] == id && h['state'] == 'draft')).toList();
        return ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
          Row(children: [
            IconButton(tooltip: 'Previous year', onPressed: () => setState(() => _year--), icon: const Icon(Icons.chevron_left_rounded)),
            Expanded(child: Text('$_year', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium)),
            IconButton(tooltip: 'Next year', onPressed: () => setState(() => _year++), icon: const Icon(Icons.chevron_right_rounded)),
          ]),
          SectionCard(
            color: AppColors.holidayCard,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('$published of $target planned holidays published', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: AppSpacing.sm),
              LinearProgressIndicator(value: target == 0 ? 1 : (published / target).clamp(0, 1).toDouble(),
                  minHeight: 8, borderRadius: BorderRadius.circular(4)),
              const SizedBox(height: AppSpacing.sm),
              Text('The target is a plan, not a legal list. You may add more. Holidays do not change paid-leave balances, '
                  'except that leave already booked on a new holiday is returned automatically.',
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
            OutlinedButton.icon(onPressed: () => _edit(null), icon: const Icon(Icons.add_rounded), label: const Text('Add holiday')),
            if (widget.isAdmin && selectable.isNotEmpty)
              FilledButton(
                onPressed: () async {
                  final ok = await confirm(context,
                      title: 'Publish ${selectable.length} holiday(s)?',
                      message: 'Schedules are updated and anyone with leave booked on these dates gets it back.',
                      confirmLabel: 'Publish');
                  if (!ok || !context.mounted) return;
                  await _run(context, () async {
                    final res = (await ref.read(apiProvider).rpc('publish_holidays', {'p_ids': selectable})).map;
                    _selected.clear();
                    _reload();
                    if (context.mounted && (res['leave_days_reconciled'] as num? ?? 0) > 0) {
                      showMessage(context, '${res['leave_days_reconciled']} booked leave day(s) were returned.');
                    }
                  }, done: 'Published.');
                },
                child: Text('Publish selected (${selectable.length})'),
              ),
          ]),
          const SizedBox(height: AppSpacing.md),
          if (list.isEmpty) const EmptyState(icon: Icons.celebration_outlined, title: 'No holidays for this year'),
          for (final h in list)
            Card(
              margin: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: ListTile(
                leading: h['state'] == 'draft' && widget.isAdmin && DateTime.parse(h['date'] as String).isAfter(today)
                    ? Checkbox(
                        value: _selected.contains(h['id']),
                        onChanged: (v) => setState(() => v == true ? _selected.add(h['id'] as String) : _selected.remove(h['id'])),
                      )
                    : Icon(h['state'] == 'published' ? Icons.event_available_rounded : Icons.edit_calendar_outlined,
                        color: AppColors.holidayText),
                title: Text(h['name'] as String),
                subtitle: Text([
                  OrgTime.date(h['date'] as String?, pattern: 'EEE, d MMM yyyy'),
                  (h['office_name'] as String?) ?? 'All offices',
                  if (h['state'] == 'draft') 'Draft',
                  if (h['source'] == 'import') 'from suggestion',
                ].join(' · ')),
                trailing: h['state'] == 'draft'
                    ? IconButton(
                        tooltip: 'Remove draft',
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () => _run(context, () async {
                          await ref.read(apiProvider).rpc('delete_holiday_draft', {'p_id': h['id']});
                          _reload();
                        }),
                      )
                    : null,
                onTap: h['state'] == 'draft' ? () => _edit(h) : null,
              ),
            ),
          const SizedBox(height: AppSpacing.xl),
          Row(children: [
            Expanded(child: Text('Suggestions', style: Theme.of(context).textTheme.titleMedium)),
            TextButton.icon(
              onPressed: _refreshing ? null : _refreshSuggestions,
              icon: _refreshing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh_rounded),
              label: const Text('Refresh'),
            ),
          ]),
          Text('From a public holiday calendar. Nothing is added until you choose "Add as draft".',
              style: Theme.of(context).textTheme.bodySmall),
          AsyncView(
            value: suggestions,
            loading: const SkeletonList(items: 2, height: 56),
            onRetry: () => ref.invalidate(_suggestionsProvider),
            builder: (s) {
              final rows = ((s['suggestions'] as List?) ?? const [])
                  .map((x) => (x as Map).cast<String, dynamic>())
                  .where((x) => x['state'] == 'new' && (x['date'] as String).startsWith('$_year'))
                  .toList();
              if (rows.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                  child: Text('No open suggestions for $_year.', style: Theme.of(context).textTheme.bodyMedium),
                );
              }
              return Column(children: [
                for (final x in rows)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(x['name'] as String),
                    subtitle: Text([
                      OrgTime.date(x['date'] as String?, pattern: 'EEE, d MMM yyyy'),
                      if (x['category'] != null) x['category'] as String,
                      if (x['existing_holiday'] != null) 'already: ${(x['existing_holiday'] as Map)['name']}',
                    ].join(' · ')),
                    trailing: Wrap(children: [
                      IconButton(
                        tooltip: 'Dismiss',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => _run(context, () async {
                          await ref.read(apiProvider).rpc('dismiss_holiday_suggestion', {'p_id': x['id']});
                          ref.invalidate(_suggestionsProvider);
                        }),
                      ),
                      IconButton(
                        tooltip: 'Add as draft',
                        icon: const Icon(Icons.playlist_add_rounded),
                        onPressed: x['existing_holiday'] != null
                            ? null
                            : () => _run(context, () async {
                                  await ref.read(apiProvider).rpc('add_holiday_from_suggestion', {'p_id': x['id'], 'p_office_id': null});
                                  _reload();
                                }, done: 'Added as a draft.'),
                      ),
                    ]),
                  ),
              ]);
            },
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('Weekly offs follow each shift\'s working days.', style: Theme.of(context).textTheme.bodySmall),
        ]);
      },
    );
  }
}
