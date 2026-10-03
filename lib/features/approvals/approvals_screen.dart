import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/auth/session_controller.dart';
import '../../core/widgets/filter_sheet.dart';
import '../../core/widgets/paged_list.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/states.dart';
import '../../core/widgets/pill_tabs.dart';
import '../home/home_providers.dart';
import '../requests/request_widgets.dart';

/// S22 — reviewer queue. Listing NEVER locks a request: the rows are a
/// minimal server projection without reasons, revisions or attachments.
class ApprovalsScreen extends ConsumerStatefulWidget {
  const ApprovalsScreen({super.key, this.initialScope});
  final String? initialScope;

  @override
  ConsumerState<ApprovalsScreen> createState() => _ApprovalsScreenState();
}

const _scopes = <(Object?, String)>[
  ('mine', 'Assigned to me'),
  ('unassigned', 'No approver'),
  ('all', 'Everyone'),
];
const _states = <(Object?, String)>[
  (null, 'All pending'),
  ('submitted', 'New'),
  ('under_review', 'In review'),
  ('withdrawal_pending', 'Withdrawals'),
  ('cancellation_pending', 'Cancellations'),
  ('completed', 'Completed'),
  ('approved', 'Approved'),
  ('rejected', 'Not approved'),
  ('cancelled', 'Cancelled'),
];

class _ApprovalsScreenState extends ConsumerState<ApprovalsScreen> {
  String? _kind;
  String? _state;
  late String _scope = const ['mine', 'unassigned', 'all'].contains(widget.initialScope) ? widget.initialScope! : 'mine';
  int _generation = 0;

  Future<void> _openFilters(bool isAdmin, bool canUsePool) async {
    final picked = await showFilterSheet(
      context,
      groups: [
        FilterGroup(
          title: 'Status',
          options: _states,
          value: _state,
          defaultValue: null,
        ),
        if (canUsePool)
          FilterGroup(
            title: 'Whose requests',
            options: isAdmin ? _scopes : _scopes.take(2).toList(),
            value: _scope,
            defaultValue: 'mine',
          ),
      ],
    );
    if (picked == null) return;
    setState(() {
      _state = picked[0] as String?;
      if (canUsePool) _scope = picked[1] as String;
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionContextProvider);
    final isAdmin = session?.isAdmin ?? false;
    final canUsePool = isAdmin || (session?.isHr ?? false);
    final api = ref.read(apiProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review requests'),
        actions: [
          FilterButton(
            activeCount: (_state != null ? 1 : 0) + (_scope != 'mine' ? 1 : 0),
            onPressed: () => _openFilters(isAdmin, canUsePool),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: PermissionGate(
        allowed: (s) => s.canReview || s.isAdmin,
        child: Column(
          children: [
            const OfflineBanner(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.page,
                AppSpacing.page,
                AppSpacing.page,
                0,
              ),
              child: PillTabs<String?>(
                options: const [
                  (null, 'All'),
                  ('leave', 'Leave'),
                  ('correction', 'Corrections'),
                  ('bank_details', 'Bank'),
                  ('profile_details', 'Profile'),
                  ('employee_details', 'Employee'),
                  ('employee_assignment', 'Assignment'),
                  ('employee_status', 'Status'),
                  ('salary_change', 'Salary'),
                  ('payslip_publish', 'Payslips'),
                ],
                value: _kind,
                onChanged: (v) => setState(() => _kind = v),
              ),
            ),
            // The list's own top padding (16) matches the space above the tabs.
            Expanded(
              child: PagedList<Map<String, dynamic>>(
                key: ValueKey('$_kind|$_state|$_scope|$_generation'),
                fetch: (cursor) async {
                  final c = cursor as (String, String)?;
                  final rows = (await api.rpc('list_review_queue', {
                    'p_kind': _kind,
                    'p_scope': _scope,
                    'p_state': _state,
                    'p_limit': 25,
                    'p_before_submitted_at': c?.$1,
                    'p_before_id': c?.$2,
                  })).list;
                  return PageResult(
                    rows,
                    next: rows.length < 25
                        ? null
                        : (
                            rows.last['submitted_at'] as String,
                            rows.last['id'] as String,
                          ),
                  );
                },
                empty: EmptyState(
                  icon: Icons.fact_check_outlined,
                  title: _state == 'completed'
                      ? 'No completed requests'
                      : 'Nothing to review',
                  message: _state == 'completed'
                      ? 'Approved, not approved and cancelled decisions appear here.'
                      : _scope == 'unassigned'
                      ? 'Every pending request has an approver.'
                      : null,
                ),
                loading: const RequestsSkeleton(),
                itemBuilder: (context, r) => RequestTile(
                  r: r,
                  showEmployee: true,
                  onTap: () => context.push('/approvals/${r['id']}', extra: r).then((_) {
                    ref.invalidate(homeSummaryProvider);
                    if (mounted) setState(() => _generation++);
                  }),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
