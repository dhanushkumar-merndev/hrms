import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/states.dart';
import '../home/home_providers.dart';
import '../requests/my_requests_screen.dart';
import '../requests/request_widgets.dart';

final leaveBalancesProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, int?>((ref, year) async {
  cacheFor(ref, const Duration(seconds: 30));
  return (await ref.read(apiProvider).rpc('get_leave_balances', {'p_leave_year': year})).map;
});

final holidaysProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, int>((ref, year) async {
  cacheFor(ref, const Duration(minutes: 15));
  return (await ref.read(apiProvider).rpc('list_holidays', {'p_year': year, 'p_office_id': null})).map;
});

String daysFromUnits(num? units) {
  final d = (units ?? 0) / 2;
  return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
}

/// S11 — balances per type (allocated / used / reserved / available) and
/// leave history. Paid leave entitlement is separate from company holidays.
class LeaveScreen extends ConsumerStatefulWidget {
  const LeaveScreen({super.key});

  @override
  ConsumerState<LeaveScreen> createState() => _LeaveScreenState();
}

class _LeaveScreenState extends ConsumerState<LeaveScreen> {
  int? _year;

  @override
  Widget build(BuildContext context) {
    final balances = ref.watch(leaveBalancesProvider(_year));
    final requests = ref.watch(myRequestsProvider('leave'));
    return Scaffold(
      appBar: AppBar(title: const Text('Leave')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/leave/apply'),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Apply leave'),
      ),
      body: Column(children: [
        const OfflineBanner(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(leaveBalancesProvider(_year));
              ref.invalidate(myRequestsProvider('leave'));
            },
            child: ListView(padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.sm, AppSpacing.page, 96), children: [
              AsyncView(
                value: balances,
                onRetry: () => ref.invalidate(leaveBalancesProvider(_year)),
                loading: const SkeletonList(items: 2, height: 110),
                builder: (d) {
                  final year = (d['leave_year'] as num).toInt();
                  final start = (d['leave_year_start_month'] as num?)?.toInt() ?? 1;
                  final rows = ((d['balances'] as List?) ?? const []).cast<Map>();
                  final label = start == 1
                      ? '$year'
                      : '${DateFormat('MMM').format(DateTime(2000, start))} $year – ${DateFormat('MMM').format(DateTime(2000, start == 1 ? 12 : start - 1))} ${year + 1}';
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      IconButton(
                          tooltip: 'Previous leave year',
                          onPressed: () => setState(() => _year = year - 1),
                          icon: const Icon(Icons.chevron_left_rounded)),
                      Expanded(
                        child: Text('Leave year $label',
                            textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
                      ),
                      IconButton(
                          tooltip: 'Next leave year',
                          onPressed: () => setState(() => _year = year + 1),
                          icon: const Icon(Icons.chevron_right_rounded)),
                    ]),
                    if (rows.isEmpty)
                      const EmptyState(
                          icon: Icons.beach_access_outlined,
                          title: 'No leave types yet',
                          message: 'Your Admin has not published leave types for this organisation.')
                    else
                      for (final b in rows) ...[
                        _BalanceCard(b.cast<String, dynamic>()),
                        const SizedBox(height: AppSpacing.md),
                      ],
                  ]);
                },
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('Leave history', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              AsyncView(
                value: requests,
                onRetry: () => ref.invalidate(myRequestsProvider('leave')),
                isEmpty: (r) => r.isEmpty,
                empty: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Text('No leave requests yet.', style: Theme.of(context).textTheme.bodyMedium),
                ),
                loading: const SkeletonList(items: 2),
                builder: (rows) => Column(children: [
                  for (final r in rows) ...[
                    RequestTile(r: r, onTap: () => context.push('/requests/${r['id']}')),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                ]),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard(this.b);
  final Map<String, dynamic> b;

  @override
  Widget build(BuildContext context) {
    final type = (b['leave_type'] as Map).cast<String, dynamic>();
    final paid = type['paid'] == true;
    Widget stat(String label, num? units) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            Text(daysFromUnits(units), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ]),
        );
    return SectionCard(
      color: AppColors.leaveCard,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(type['name'] as String, style: Theme.of(context).textTheme.titleMedium)),
          if (paid)
            Text.rich(TextSpan(children: [
              TextSpan(text: daysFromUnits(b['available_units'] as num?),
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: AppColors.leaveAction)),
              const TextSpan(text: ' days left', style: TextStyle(color: AppColors.leaveAction)),
            ]))
          else
            const StatusChip('Unpaid', tone: ChipTone.neutral),
        ]),
        if (paid) ...[
          const SizedBox(height: AppSpacing.md),
          Row(children: [
            stat('Allocated', b['allocated_units'] as num?),
            stat('Used', b['used_units'] as num?),
            stat('Pending', b['reserved_units'] as num?),
            if (((b['expired_units'] as num?) ?? 0) > 0) stat('Expired', b['expired_units'] as num?),
          ]),
        ],
      ]),
    );
  }
}

/// S13 — company holiday calendar (published), separate from leave balance.
class HolidaysScreen extends ConsumerStatefulWidget {
  const HolidaysScreen({super.key});

  @override
  ConsumerState<HolidaysScreen> createState() => _HolidaysScreenState();
}

class _HolidaysScreenState extends ConsumerState<HolidaysScreen> {
  late int _year = OrgTime.today().year;

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(holidaysProvider(_year));
    return Scaffold(
      appBar: AppBar(title: const Text('Holiday calendar')),
      body: Column(children: [
        const OfflineBanner(),
        Row(children: [
          IconButton(
              tooltip: 'Previous year', onPressed: () => setState(() => _year--), icon: const Icon(Icons.chevron_left_rounded)),
          Expanded(child: Text('$_year', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium)),
          IconButton(tooltip: 'Next year', onPressed: () => setState(() => _year++), icon: const Icon(Icons.chevron_right_rounded)),
        ]),
        Expanded(
          child: AsyncView(
            value: data,
            onRetry: () => ref.invalidate(holidaysProvider(_year)),
            builder: (d) {
              final list = ((d['holidays'] as List?) ?? const []).cast<Map>();
              final published = list.where((h) => h['state'] == 'published').length;
              final today = OrgTime.today();
              return ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
                SectionCard(
                  color: AppColors.holidayCard,
                  child: Text(
                    '$published of ${d['target']} planned company holidays published for $_year. '
                    'Weekly offs follow your shift. Holidays are separate from your leave balance.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                if (d['can_manage'] == true)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => context.push('/admin/leave-policies?tab=holidays'),
                      icon: const Icon(Icons.edit_calendar_outlined),
                      label: const Text('Manage holidays'),
                    ),
                  ),
                if (list.isEmpty)
                  const EmptyState(icon: Icons.celebration_outlined, title: 'No holidays published for this year'),
                for (final h in list)
                  Card(
                    margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: AppColors.holidayCard,
                        child: Text(OrgTime.date(h['date'] as String?, pattern: 'd'),
                            style: const TextStyle(color: AppColors.holidayText, fontWeight: FontWeight.w700)),
                      ),
                      title: Text(h['name'] as String),
                      subtitle: Text([
                        OrgTime.date(h['date'] as String?, pattern: 'EEEE, d MMMM'),
                        if (h['office_name'] != null) h['office_name'] as String,
                        if (h['state'] == 'draft') 'Draft',
                        if ((DateTime.tryParse(h['date'] as String? ?? '') ?? today).isBefore(today)) 'Past',
                      ].join(' · ')),
                    ),
                  ),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}
