import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/illustration.dart';
import '../../core/widgets/states.dart';
import '../home/home_providers.dart';
import '../requests/my_requests_screen.dart';
import '../requests/request_widgets.dart';

final leaveBalancesProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, int?>((ref, year) async {
      cacheFor(ref, const Duration(seconds: 30));
      return (await ref.read(apiProvider).rpc('get_leave_balances', {
        'p_leave_year': year,
      })).map;
    });

final holidaysProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, int>((ref, year) async {
      cacheFor(ref, const Duration(minutes: 15));
      return (await ref.read(apiProvider).rpc('list_holidays', {
        'p_year': year,
        'p_office_id': null,
      })).map;
    });

String daysFromUnits(num? units) {
  final d = (units ?? 0) / 2;
  return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
}

const _holidayArtOrder = [
  12,
  3,
  18,
  7,
  15,
  1,
  20,
  9,
  5,
  14,
  2,
  17,
  11,
  21,
  6,
  16,
  4,
  13,
  8,
  19,
  10,
];

/// A stable shuffled illustration assignment. The first 21 holidays in a
/// year are guaranteed to use different artwork; only the 22nd can repeat.
int holidayIllustrationNumber(int index, int year) =>
    _holidayArtOrder[(index + year.remainder(_holidayArtOrder.length)) %
        _holidayArtOrder.length];

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
        icon: const AppIcon(Icons.add_rounded),
        label: const Text('Apply leave'),
      ),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(leaveBalancesProvider(_year));
                ref.invalidate(myRequestsProvider('leave'));
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  AppSpacing.sm,
                  AppSpacing.page,
                  96,
                ),
                children: [
                  AsyncView(
                    value: balances,
                    onRetry: () => ref.invalidate(leaveBalancesProvider(_year)),
                    loading: const LeaveSkeleton(),
                    builder: (d) {
                      final year = (d['leave_year'] as num).toInt();
                      final start =
                          (d['leave_year_start_month'] as num?)?.toInt() ?? 1;
                      final rows = ((d['balances'] as List?) ?? const [])
                          .cast<Map>();
                      final label = start == 1
                          ? '$year'
                          : '${DateFormat('MMM').format(DateTime(2000, start))} $year – ${DateFormat('MMM').format(DateTime(2000, start == 1 ? 12 : start - 1))} ${year + 1}';
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              IconButton(
                                tooltip: 'Previous leave year',
                                onPressed: () =>
                                    setState(() => _year = year - 1),
                                icon: const AppIcon(Icons.chevron_left_rounded),
                              ),
                              Expanded(
                                child: Text(
                                  'Leave year $label',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Next leave year',
                                onPressed: () =>
                                    setState(() => _year = year + 1),
                                icon: const AppIcon(Icons.chevron_right_rounded),
                              ),
                            ],
                          ),
                          if (rows.isEmpty)
                            const EmptyState(
                              icon: Icons.beach_access_outlined,
                              title: 'No leave types yet',
                              message: 'Your Admin has not published leave types for this organisation.',
                            )
                          else
                            for (final b in rows) ...[
                              _BalanceCard(b.cast<String, dynamic>()),
                              const SizedBox(height: AppSpacing.md),
                            ],
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    'Leave history',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AsyncView(
                    value: requests,
                    onRetry: () => ref.invalidate(myRequestsProvider('leave')),
                    isEmpty: (r) => r.isEmpty,
                    empty: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Text(
                        'No leave requests yet.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    loading: const SkeletonList(items: 2),
                    builder: (rows) => Column(
                      children: [
                        for (final r in rows) ...[
                          RequestTile(
                            r: r,
                            onTap: () => context.push('/requests/${r['id']}'),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          Text(
            daysFromUnits(units),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
    return SectionCard(
      color: AppColors.leaveCard,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  type['name'] as String,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (paid)
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: daysFromUnits(b['available_units'] as num?),
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          color: AppColors.leaveAction,
                        ),
                      ),
                      const TextSpan(
                        text: ' days left',
                        style: TextStyle(color: AppColors.leaveAction),
                      ),
                    ],
                  ),
                )
              else
                const StatusChip('Unpaid', tone: ChipTone.neutral),
            ],
          ),
          if (paid) ...[
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                stat('Allocated', b['allocated_units'] as num?),
                stat('Used', b['used_units'] as num?),
                stat('Pending', b['reserved_units'] as num?),
                if (((b['expired_units'] as num?) ?? 0) > 0)
                  stat('Expired', b['expired_units'] as num?),
              ],
            ),
          ],
        ],
      ),
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
      body: Column(
        children: [
          const OfflineBanner(),
          Row(
            children: [
              IconButton(
                tooltip: 'Previous year',
                onPressed: () => setState(() => _year--),
                icon: const AppIcon(Icons.chevron_left_rounded),
              ),
              Expanded(
                child: Text(
                  '$_year',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Next year',
                onPressed: () => setState(() => _year++),
                icon: const AppIcon(Icons.chevron_right_rounded),
              ),
            ],
          ),
          Expanded(
            child: AsyncView(
              value: data,
              onRetry: () => ref.invalidate(holidaysProvider(_year)),
              builder: (d) {
                final list = ((d['holidays'] as List?) ?? const []).cast<Map>();
                final published = list
                    .where((h) => h['state'] == 'published')
                    .length;
                final today = OrgTime.today();
                return ListView(
                  padding: const EdgeInsets.all(AppSpacing.page),
                  children: [
                    SectionCard(
                      color: AppColors.holidayCard,
                      child: Row(
                        children: [
                          const AppIcon(
                            Icons.event_available_rounded,
                            color: AppColors.holidayText,
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '$published holidays in $_year',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'No attendance or leave is needed on published holidays.',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (d['can_manage'] == true)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () => context.push(
                            '/admin/leave-policies?tab=holidays',
                          ),
                          icon: const AppIcon(Icons.edit_calendar_outlined),
                          label: const Text('Manage holidays'),
                        ),
                      ),
                    if (list.isEmpty)
                      const EmptyState(
                        icon: Icons.celebration_outlined,
                        title: 'No holidays published for this year',
                      ),
                    for (var i = 0; i < list.length; i++)
                      _HolidayCard(
                        holiday: list[i].cast<String, dynamic>(),
                        illustration: holidayIllustrationNumber(i, _year),
                        today: today,
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _HolidayCard extends StatelessWidget {
  const _HolidayCard({
    required this.holiday,
    required this.illustration,
    required this.today,
  });
  final Map<String, dynamic> holiday;
  final int illustration;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final date = DateTime.tryParse(holiday['date'] as String? ?? '');
    final past = date?.isBefore(today) ?? false;
    final draft = holiday['state'] == 'draft';
    final card = Opacity(
      opacity: past ? 0.68 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 50,
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              decoration: BoxDecoration(
                color: AppColors.holidayCard,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Text(
                    date == null
                        ? '—'
                        : DateFormat('MMM').format(date).toUpperCase(),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.holidayText,
                    ),
                  ),
                  Text(
                    date == null ? '—' : '${date.day}',
                    style: const TextStyle(
                      fontSize: 20,
                      height: 1.05,
                      fontWeight: FontWeight.w800,
                      color: AppColors.text,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    holiday['name'] as String? ?? 'Holiday',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    [
                      if (date != null) DateFormat('EEEE').format(date),
                      if (holiday['office_name'] != null)
                        holiday['office_name'] as String,
                      if (draft) 'Draft',
                      if (past) 'Past',
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Illustration('holiday$illustration', size: 48),
          ],
        ),
      ),
    );
    if (!past) return card;
    return ColorFiltered(
      key: ValueKey('past-holiday-${holiday['id'] ?? holiday['date']}'),
      colorFilter: const ColorFilter.matrix([
        0.2126,
        0.7152,
        0.0722,
        0,
        0,
        0.2126,
        0.7152,
        0.0722,
        0,
        0,
        0.2126,
        0.7152,
        0.0722,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ]),
      child: card,
    );
  }
}
