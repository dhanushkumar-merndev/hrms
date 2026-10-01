import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/filter_sheet.dart';
import '../../core/widgets/paged_list.dart';
import '../../core/widgets/pill_tabs.dart';
import '../../core/widgets/states.dart';
import '../files/file_viewer_screen.dart';
import '../home/home_providers.dart';
import 'request_widgets.dart';

final myRequestsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String?>((ref, kind) async {
      final res = await ref.read(apiProvider).rpc('list_my_requests', {
        'p_kind': kind,
        'p_limit': 100,
      });
      return res.list;
    });

final myRequestProvider = FutureProvider.autoDispose.family<ApiResult, String>((
  ref,
  id,
) async {
  return ref.read(apiProvider).rpc('get_my_request', {'p_request_id': id});
});

/// Own leave, attendance-correction and bank-detail requests.
class MyRequestsScreen extends ConsumerStatefulWidget {
  const MyRequestsScreen({super.key});

  @override
  ConsumerState<MyRequestsScreen> createState() => _MyRequestsScreenState();
}

class _MyRequestsScreenState extends ConsumerState<MyRequestsScreen> {
  String? _kind;
  String? _state;
  int _generation = 0;

  static const _states = <(Object?, String)>[
    (null, 'All'),
    ('active', 'Active'),
    ('returned', 'Returned'),
    ('completed', 'Completed'),
    ('approved', 'Approved'),
    ('rejected', 'Not approved'),
    ('cancelled', 'Cancelled'),
  ];

  Future<void> _openFilters() async {
    final picked = await showFilterSheet(
      context,
      groups: [
        FilterGroup(
          title: 'Status',
          options: _states,
          value: _state,
          defaultValue: null,
        ),
      ],
    );
    if (picked == null) return;
    setState(() => _state = picked.single as String?);
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.read(apiProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('My requests'),
        actions: [
          FilterButton(
            activeCount: _state == null ? 0 : 1,
            onPressed: _openFilters,
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: Column(
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
              ],
              value: _kind,
              onChanged: (v) => setState(() => _kind = v),
            ),
          ),
          Expanded(
            child: PagedList<Map<String, dynamic>>(
              key: ValueKey('$_kind|$_state|$_generation'),
              fetch: (cursor) async {
                final c = cursor as (String, String)?;
                final rows = (await api.rpc('list_my_requests', {
                  'p_kind': _kind,
                  'p_state': _state,
                  'p_limit': 25,
                  'p_before_created_at': c?.$1,
                  'p_before_id': c?.$2,
                })).list;
                return PageResult(
                  rows,
                  next: rows.length < 25
                      ? null
                      : (
                          rows.last['created_at'] as String,
                          rows.last['id'] as String,
                        ),
                );
              },
              empty: EmptyState(
                icon: Icons.assignment_outlined,
                title: _state == null
                    ? 'No requests yet'
                    : 'No ${_states.firstWhere((s) => s.$1 == _state).$2.toLowerCase()} requests',
                message: _state == 'completed'
                    ? 'Approved, not approved and cancelled requests appear here.'
                    : null,
              ),
              itemBuilder: (context, r) => RequestTile(
                r: r,
                onTap: () => context.push('/requests/${r['id']}').then((_) {
                  if (mounted) setState(() => _generation++);
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// S10 — owner's request detail. Reading it never locks the request.
class RequestDetailScreen extends ConsumerStatefulWidget {
  const RequestDetailScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<RequestDetailScreen> createState() =>
      _RequestDetailScreenState();
}

class _RequestDetailScreenState extends ConsumerState<RequestDetailScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(myRequestProvider(widget.id));
      ref.invalidate(myRequestsProvider);
      ref.invalidate(homeSummaryProvider);
    } on ApiException catch (e) {
      if (!mounted) return;
      showMessage(context, e.message, error: true);
      if (e.code == 'STALE_VERSION' || e.code == 'REQUEST_LOCKED')
        ref.invalidate(myRequestProvider(widget.id));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(myRequestProvider(widget.id));
    final api = ref.read(apiProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Request')),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(myRequestProvider(widget.id)),
        builder: (res) {
          final r = res.map;
          final version = res.version;
          final state = r['state'] as String;
          final kind = r['kind'] as String;
          final (label, tone) = requestState(state);
          final revisions = ((r['revisions'] as List?) ?? const []).cast<Map>();
          final latest = revisions.isEmpty
              ? <String, dynamic>{}
              : (revisions.last['payload'] as Map).cast<String, dynamic>();
          final events = ((r['events'] as List?) ?? const []).cast<Map>();
          final returnReason = events.lastWhere(
            (e) => e['action'] == 'returned',
            orElse: () => const {},
          )['reason'];
          final editable =
              state == 'submitted' || state == 'returned' || state == 'draft';
          final editPath = switch (kind) {
            'leave' => '/leave/apply?edit=${widget.id}',
            'bank_details' => '/salary/bank-details?edit=${widget.id}',
            _ => '/corrections/new?edit=${widget.id}',
          };

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.page),
            children: [
              SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      requestTitle(r),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        StatusChip(label, tone: tone),
                        if (r['edited'] == true)
                          StatusChip(
                            'Edited · version ${r['current_revision']}',
                            tone: ChipTone.neutral,
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _LockNote(
                      state: state,
                      reviewer: (r['reviewer'] as Map?)?['name'] as String?,
                      assigned: r['reviewer_assigned'] == true,
                    ),
                    if (state == 'returned' && returnReason != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(AppSpacing.md),
                        decoration: BoxDecoration(
                          color: AppColors.warningSoft,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'Approver\'s note: “$returnReason”\n'
                          '${kind == 'leave' ? 'The balance held for this request was released. Resubmitting checks availability again.' : ''}',
                          style: const TextStyle(color: AppColors.warning),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              SectionCard(
                child: RevisionView(
                  kind: kind,
                  payload: latest,
                  onViewAttachment: latest['attachment_file_version_id'] == null
                      ? null
                      : () => openProtectedFile(
                          context,
                          latest['attachment_file_version_id'] as String,
                          'Attachment',
                        ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              SectionCard(child: EventTimeline(events: events)),
              const SizedBox(height: AppSpacing.xl),
              if (editable)
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => context
                            .push(editPath)
                            .then(
                              (_) =>
                                  ref.invalidate(myRequestProvider(widget.id)),
                            ),
                  icon: const AppIcon(Icons.edit_outlined),
                  label: Text(state == 'returned' ? 'Edit & resubmit' : 'Edit'),
                ),
              if (editable || state == 'under_review') ...[
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final reason = await askReason(
                            context,
                            title: state == 'under_review'
                                ? 'Ask to withdraw?'
                                : 'Withdraw request?',
                            message: state == 'under_review'
                                ? 'Your approver has opened this request, so they must accept the withdrawal.'
                                : null,
                            optional: true,
                            confirmLabel: 'Withdraw',
                          );
                          if (reason == null) return;
                          await _run(
                            () => api.rpc('withdraw_request', {
                              'p_request_id': widget.id,
                              'p_expected_version': version,
                              'p_reason': reason,
                            }),
                          );
                        },
                  child: Text(
                    state == 'under_review' ? 'Request withdrawal' : 'Withdraw',
                  ),
                ),
              ],
              if (state == 'approved' && kind == 'leave')
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final reason = await askReason(
                            context,
                            title: 'Cancel approved leave?',
                            message: 'Your approver must approve the cancellation. The leave stays booked until then.',
                            confirmLabel: 'Request cancellation',
                          );
                          if (reason == null) return;
                          await _run(
                            () => api.rpc('request_leave_cancellation', {
                              'p_request_id': widget.id,
                              'p_expected_version': version,
                              'p_reason': reason,
                            }),
                          );
                        },
                  child: const Text('Request cancellation'),
                ),
              if (state == 'approved' && kind == 'correction')
                Text(
                  'To change an approved correction, submit a new correction for that day.',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              if (state == 'approved' && kind == 'bank_details')
                Text(
                  'These bank details are locked. Start a new change request from My salary if your account changes.',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _LockNote extends StatelessWidget {
  const _LockNote({
    required this.state,
    required this.reviewer,
    required this.assigned,
  });
  final String state;
  final String? reviewer;
  final bool assigned;

  @override
  Widget build(BuildContext context) {
    final text = switch (state) {
      'submitted' =>
        assigned
            ? 'Editable until your approver${reviewer != null ? ' ($reviewer)' : ''} opens this request.'
            : 'Waiting for an approver to be assigned. You can still edit it.',
      'under_review' => 'In review — contact your approver for changes.',
      'returned' => 'Returned to you. Edit and resubmit, or withdraw.',
      'withdrawal_pending' =>
        'Waiting for your approver to accept the withdrawal.',
      'cancellation_pending' => 'Waiting for your approver to approve the cancellation. The leave stays booked until then.',
      'approved' => 'Approved${reviewer != null ? ' by $reviewer' : ''}.',
      'rejected' => 'Not approved.',
      'cancelled' => 'Cancelled.',
      _ => '',
    };
    return Row(
      children: [
        AppIcon(
          state == 'submitted' || state == 'returned'
              ? Icons.lock_open_rounded
              : Icons.lock_outline_rounded,
          size: 18,
          color: AppColors.textSecondary,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    );
  }
}
