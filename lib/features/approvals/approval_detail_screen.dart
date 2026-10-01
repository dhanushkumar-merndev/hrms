import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/auth/session_controller.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/pickers.dart';
import '../../core/widgets/states.dart';
import '../files/file_viewer_screen.dart';
import '../home/home_providers.dart';
import '../leave/leave_screen.dart';
import '../requests/request_widgets.dart';

/// S23 — reviewer detail. The server locks the CURRENT revision and returns
/// exactly that revision in one transaction (open_request_for_review); this
/// screen never reads request details any other way. Every decision sends
/// the version it was shown, so a stale view can never approve.
class ApprovalDetailScreen extends ConsumerStatefulWidget {
  const ApprovalDetailScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<ApprovalDetailScreen> createState() =>
      _ApprovalDetailScreenState();
}

class _ApprovalDetailScreenState extends ConsumerState<ApprovalDetailScreen> {
  ApiResult? _res;
  Object? _error;
  bool _busy = false;
  bool _needsFallbackReason = false;

  @override
  void initState() {
    super.initState();
    _open(null);
  }

  Future<void> _open(String? reason) async {
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final res = await ref.read(apiProvider).rpc('open_request_for_review', {
        'p_request_id': widget.id,
        'p_reason': reason,
      });
      if (!mounted) return;
      setState(() {
        _res = res;
        _needsFallbackReason = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.code == 'VALIDATION_FAILED' &&
            e.fieldErrors.containsKey('reason')) {
          _needsFallbackReason = true;
        } else {
          _error = e;
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _act(
    String done,
    Future<ApiResult> Function(ApiClient api) call,
  ) async {
    setState(() => _busy = true);
    try {
      await call(ref.read(apiProvider));
      ref.invalidate(homeSummaryProvider);
      if (!mounted) return;
      showMessage(context, done);
      context.pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      showMessage(context, e.message, error: true);
      if (e.code == 'STALE_VERSION' || e.code == 'REQUEST_LOCKED')
        await _open(null);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decide(
    String decision,
    int? version, {
    required bool reasonRequired,
    required String title,
  }) async {
    final reason = await askReason(
      context,
      title: title,
      optional: !reasonRequired,
      confirmLabel: switch (decision) {
        'approve' => 'Approve',
        'reject' => 'Not approve',
        _ => 'Return',
      },
      destructive: decision == 'reject',
    );
    if (reason == null) return;
    await _act(
      switch (decision) {
        'approve' => 'Approved.',
        'reject' => 'Marked not approved.',
        _ => 'Returned for changes.',
      },
      (api) => api.rpc('decide_request', {
        'p_request_id': widget.id,
        'p_decision': decision,
        'p_reason': reason.isEmpty ? null : reason,
        'p_expected_version': version,
      }),
    );
  }

  Future<void> _resolve(
    String fn,
    bool accept,
    int? version, {
    required bool reasonRequired,
  }) async {
    final reason = await askReason(
      context,
      title: accept ? 'Accept?' : 'Decline?',
      optional: !reasonRequired,
      confirmLabel: accept ? 'Accept' : 'Decline',
    );
    if (reason == null) return;
    await _act(
      accept ? 'Accepted.' : 'Declined.',
      (api) => api.rpc(fn, {
        'p_request_id': widget.id,
        'p_accept': accept,
        'p_reason': reason.isEmpty ? null : reason,
        'p_expected_version': version,
      }),
    );
  }

  Future<void> _reassign(int? version, String employeeId) async {
    final who = await pickEmployee(
      context,
      title: 'Assign to approver',
      source: 'reviewers',
      excludeId: employeeId,
    );
    if (who == null || !mounted) return;
    final reason = await askReason(
      context,
      title: 'Reassign to ${who['name']}?',
      confirmLabel: 'Reassign',
    );
    if (reason == null) return;
    await _act(
      'Reassigned.',
      (api) => api.rpc('reassign_request', {
        'p_request_id': widget.id,
        'p_new_reviewer_id': who['id'],
        'p_reason': reason,
        'p_expected_version': version,
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(sessionContextProvider)?.isAdmin ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Review request')),
      body: PermissionGate(
        allowed: (s) => s.canReview || s.isAdmin,
        child: _needsFallbackReason
            ? _FallbackPrompt(busy: _busy, onReason: _open)
            : _error != null
            ? ErrorState(error: _error!, onRetry: () => _open(null))
            : _res == null
            ? const SkeletonList(items: 3, height: 120)
            : _body(context, _res!, isAdmin),
      ),
    );
  }

  Widget _body(BuildContext context, ApiResult res, bool isAdmin) {
    final r = res.map;
    final version = res.version;
    final state = r['state'] as String;
    final kind = r['kind'] as String;
    final (label, tone) = requestState(state);
    final employee = (r['employee'] as Map).cast<String, dynamic>();
    final revisions = ((r['revisions'] as List?) ?? const []).cast<Map>();
    final current = revisions.isEmpty
        ? <String, dynamic>{}
        : (revisions.last['payload'] as Map).cast<String, dynamic>();
    final events = ((r['events'] as List?) ?? const []).cast<Map>();
    final balance = ((r['balance'] as List?) ?? const []).cast<Map>();
    final conflicts = (r['attendance_conflicts'] as num?)?.toInt() ?? 0;
    final adminFallback = r['authority'] == 'admin';
    final attachment = current['attachment_file_version_id'] as String?;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.page),
      children: [
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${employee['name']} · ${employee['code']}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                '${requestTitle(r)} · ${requestDates(r)}',
                style: Theme.of(context).textTheme.bodyLarge,
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
                  if (adminFallback)
                    const StatusChip('Admin fallback', tone: ChipTone.warning),
                  if (kind == 'bank_details' && current['mode'] == 'change')
                    const StatusChip(
                      'Admin approval required',
                      tone: ChipTone.warning,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  const AppIcon(
                    Icons.lock_outline_rounded,
                    size: 18,
                    color: AppColors.textSecondary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'You are reviewing version ${r['locked_revision'] ?? r['current_revision']}. '
                      'The employee can no longer edit it; return it if changes are needed.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (kind == 'leave') ...[
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            color: conflicts > 0 ? AppColors.errorSoft : AppColors.leaveCard,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Balance impact',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'This request: ${unitsLabel(r['units'] as num?)}'
                  '${(current['days'] as List?)?.isEmpty ?? true ? '' : ' (holidays and weekly offs excluded)'}',
                ),
                for (final b in balance)
                  Text(
                    'Leave year ${b['leave_year']}: ${daysFromUnits(b['available'] as num?)} days available after holds',
                  ),
                if (balance.isEmpty)
                  const Text('No balance is allocated for this leave type.'),
                if (conflicts > 0) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Attendance was recorded on $conflicts of these day(s). Approving is blocked; return it instead.',
                    style: const TextStyle(color: AppColors.error),
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        SectionCard(
          child: RevisionView(
            kind: kind,
            payload: current,
            onViewAttachment: attachment == null
                ? null
                : () => openProtectedFile(
                    context,
                    attachment,
                    'Attachment',
                    purpose: 'review',
                  ),
          ),
        ),
        if (kind == 'correction') ...[
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: () => context.push(
              '/attendance/day?date=${r['target_shift_date']}&employee=${employee['id']}',
            ),
            icon: const AppIcon(Icons.event_note_outlined),
            label: const Text('View recorded attendance for this day'),
          ),
        ],
        if (revisions.length > 1) ...[
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                'Earlier versions (${revisions.length - 1})',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              children: [
                for (final rv in revisions.reversed.skip(1))
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Version ${rv['revision_no']}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        RevisionView(
                          kind: kind,
                          payload: (rv['payload'] as Map)
                              .cast<String, dynamic>(),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        SectionCard(child: EventTimeline(events: events)),
        const SizedBox(height: AppSpacing.xl),
        ..._actions(
          state,
          version,
          adminFallback,
          employee['id'] as String,
          isAdmin,
          conflicts,
        ),
      ],
    );
  }

  List<Widget> _actions(
    String state,
    int? version,
    bool adminFallback,
    String employeeId,
    bool isAdmin,
    int conflicts,
  ) {
    final gap = const SizedBox(height: AppSpacing.sm);
    final out = <Widget>[];
    if (state == 'under_review') {
      out.addAll([
        FilledButton.icon(
          onPressed: _busy || conflicts > 0
              ? null
              : () => _decide(
                  'approve',
                  version,
                  reasonRequired: adminFallback,
                  title: 'Approve this request?',
                ),
          icon: const AppIcon(Icons.check_rounded),
          label: const Text('Approve'),
        ),
        gap,
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _decide(
                  'return',
                  version,
                  reasonRequired: true,
                  title: 'Return for changes',
                ),
          icon: const AppIcon(Icons.undo_rounded),
          label: const Text('Return for changes'),
        ),
        gap,
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: AppColors.error),
          onPressed: _busy
              ? null
              : () => _decide(
                  'reject',
                  version,
                  reasonRequired: true,
                  title: 'Not approve this request?',
                ),
          icon: const AppIcon(Icons.close_rounded),
          label: const Text('Not approve'),
        ),
      ]);
    } else if (state == 'withdrawal_pending') {
      out.addAll([
        Text(
          'The employee asked to withdraw this request.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        gap,
        FilledButton(
          onPressed: _busy
              ? null
              : () => _resolve(
                  'resolve_withdrawal',
                  true,
                  version,
                  reasonRequired: adminFallback,
                ),
          child: const Text('Accept withdrawal'),
        ),
        gap,
        OutlinedButton(
          onPressed: _busy
              ? null
              : () => _resolve(
                  'resolve_withdrawal',
                  false,
                  version,
                  reasonRequired: true,
                ),
          child: const Text('Decline withdrawal'),
        ),
      ]);
    } else if (state == 'cancellation_pending') {
      out.addAll([
        Text(
          'The employee asked to cancel this approved leave. It stays booked until you decide.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        gap,
        FilledButton(
          onPressed: _busy
              ? null
              : () => _resolve(
                  'resolve_cancellation',
                  true,
                  version,
                  reasonRequired: adminFallback,
                ),
          child: const Text('Approve cancellation'),
        ),
        gap,
        OutlinedButton(
          onPressed: _busy
              ? null
              : () => _resolve(
                  'resolve_cancellation',
                  false,
                  version,
                  reasonRequired: true,
                ),
          child: const Text('Keep the leave approved'),
        ),
      ]);
    } else {
      out.add(
        Text(
          'No action is needed on this request now.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    if (isAdmin &&
        const {
          'submitted',
          'under_review',
          'withdrawal_pending',
          'cancellation_pending',
        }.contains(state)) {
      out.addAll([
        const SizedBox(height: AppSpacing.lg),
        TextButton.icon(
          onPressed: _busy ? null : () => _reassign(version, employeeId),
          icon: const AppIcon(Icons.swap_horiz_rounded),
          label: const Text('Reassign to another approver'),
        ),
      ]);
    }
    return out;
  }
}

class _FallbackPrompt extends StatelessWidget {
  const _FallbackPrompt({required this.busy, required this.onReason});
  final bool busy;
  final ValueChanged<String?> onReason;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.page),
      children: [
        SectionCard(
          color: AppColors.warningSoft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'You are not the assigned approver',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: AppSpacing.sm),
              const Text(
                'As Admin you can review this request as a fallback. Opening it locks the current version '
                'for editing, and your reason is recorded in the audit history.',
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        final reason = await askReason(
                          context,
                          title: 'Reason for Admin review',
                          confirmLabel: 'Open request',
                        );
                        if (reason != null) onReason(reason);
                      },
                child: const Text('Review as Admin'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
