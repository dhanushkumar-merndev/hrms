import '../../core/widgets/app_icon.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/auth/session_controller.dart';
import '../../core/device/device_key.dart';
import '../../core/device/local_auth.dart';
import '../../core/format.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import 'salary_widgets.dart';

/// Own salary as a bank-card. Nothing is loaded until the person confirms
/// with their fingerprint (or screen lock); the figures are dropped again
/// when they tap Hide, after a minute, or as soon as the app goes to the
/// background. Screenshots and the recent-apps preview are blocked here.
class MySalaryScreen extends ConsumerStatefulWidget {
  const MySalaryScreen({super.key, this.auth = const LocalAuth()});
  final LocalAuth auth;

  @override
  ConsumerState<MySalaryScreen> createState() => _MySalaryScreenState();
}

class _MySalaryScreenState extends ConsumerState<MySalaryScreen> {
  static const _autoHide = Duration(seconds: 60);
  Map<String, dynamic>? _data;
  bool _busy = false;
  bool _confirming = false;
  int _secondsLeft = 0;
  Timer? _timer;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    widget.auth.secureScreen(true);
    _lifecycle = AppLifecycleListener(
      // The fingerprint sheet can briefly background the app; ignore that.
      onHide: () {
        if (!_confirming) _hide();
      },
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle.dispose();
    widget.auth.secureScreen(false);
    super.dispose();
  }

  void _hide() {
    _timer?.cancel();
    if (mounted && (_data != null || _secondsLeft != 0)) {
      setState(() {
        _data = null;
        _secondsLeft = 0;
      });
    }
  }

  Future<void> _toggle() async {
    if (_data != null) return _hide();
    setState(() => _busy = true);
    try {
      _confirming = true;
      final ok = await widget.auth.confirm(
        title: 'Show your salary',
        subtitle: 'Confirm it is you',
      );
      _confirming = false;
      if (!ok) return;
      final res = await ref.read(apiProvider).rpc('get_my_salary');
      if (!mounted) return;
      setState(() {
        _data = res.map;
        _secondsLeft = _autoHide.inSeconds;
      });
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _secondsLeft <= 1) {
          _hide();
        } else {
          setState(() => _secondsLeft--);
        }
      });
    } on DeviceKeyException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    } finally {
      _confirming = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final revealed = d != null;
    final profile = (d?['profile'] as Map?)?.cast<String, dynamic>();
    final bankRequest = (d?['bank_request'] as Map?)?.cast<String, dynamic>();
    final currency = (profile?['currency'] as String?) ?? 'INR';
    final recent = ((d?['recent'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    final name = ref.watch(sessionContextProvider)?.name;
    final t = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('My salary')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.lg,
          AppSpacing.page,
          AppSpacing.xxl,
        ),
        children: [
          Row(
            children: [
              const AppIcon(
                Icons.lock_outline_rounded,
                size: 17,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  revealed
                      ? 'Visible for $_secondsLeft second${_secondsLeft == 1 ? '' : 's'} · tap the card to hide'
                      : 'Private · protected by your phone lock',
                  style: t.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Align(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: SalaryCard(
                revealed: revealed,
                profile: profile,
                holderFallback: name,
                busy: _busy,
                onTap: _toggle,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          if (!revealed)
            _FloatingPanel(
              onTap: _busy ? null : _toggle,
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: AppColors.attendanceCard,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const AppIcon(
                      Icons.fingerprint_rounded,
                      color: AppColors.primary,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Reveal salary', style: t.titleSmall),
                        const SizedBox(height: 2),
                        Text(
                          'Confirm it is you with fingerprint or phone lock',
                          style: t.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  const AppIcon(Icons.chevron_right_rounded),
                ],
              ),
            )
          else if (profile == null)
            const _FloatingPanel(
              child: Row(
                children: [
                  AppIcon(
                    Icons.info_outline_rounded,
                    color: AppColors.salaryAction,
                  ),
                  SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text('HR has not added your salary details yet.'),
                  ),
                ],
              ),
            )
          else ...[
            _FloatingPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Pay summary', style: t.titleSmall),
                  const SizedBox(height: AppSpacing.lg),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _SummaryStat(
                          icon: Icons.savings_outlined,
                          label: 'Received so far',
                          value: money(d['lifetime_paid'], currency: currency),
                        ),
                      ),
                      Container(width: 1, height: 64, color: AppColors.border),
                      Expanded(
                        child: _SummaryStat(
                          icon: Icons.event_repeat_rounded,
                          label: 'Months paid',
                          value: '${d['paid_months'] ?? 0}',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            _FloatingPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Recent salary', style: t.titleSmall),
                  const SizedBox(height: AppSpacing.sm),
                  if (recent.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.sm,
                      ),
                      child: Text(
                        'No payslips published yet.',
                        style: t.bodyMedium,
                      ),
                    )
                  else
                    for (var i = 0; i < recent.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      _SalaryRow(
                        record: recent[i],
                        currency: currency,
                        onTap: () => context.push('/payslips'),
                      ),
                    ],
                ],
              ),
            ),
          ],
          if (revealed) ...[
            const SizedBox(height: AppSpacing.lg),
            _BankDetailsPanel(profile: profile, request: bankRequest),
          ],
          const SizedBox(height: AppSpacing.lg),
          FilledButton.tonalIcon(
            onPressed: () => context.push('/payslips'),
            icon: const AppIcon(Icons.picture_as_pdf_outlined),
            label: const Text('View all payslips'),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Amounts are entered by HR. This app does not calculate salary or tax.',
            textAlign: TextAlign.center,
            style: t.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _BankDetailsPanel extends StatelessWidget {
  const _BankDetailsPanel({required this.profile, required this.request});
  final Map<String, dynamic>? profile;
  final Map<String, dynamic>? request;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final approved = profile?['bank_status'] == 'approved';
    final pending = request != null;
    final state = request?['state'] as String?;
    final stateLabel = switch (state) {
      'under_review' => 'In review',
      'returned' => 'Needs changes',
      'submitted' => 'Submitted',
      _ => 'Pending',
    };
    final stateColor = state == 'returned'
        ? AppColors.warning
        : AppColors.primary;

    return _FloatingPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.salaryCard,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const AppIcon(
                  Icons.account_balance_outlined,
                  color: AppColors.salaryAction,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Salary account', style: t.titleSmall),
                    Text(
                      pending
                          ? 'A request is waiting for approval'
                          : approved
                          ? 'Approved and locked'
                          : 'Add an account for salary payments',
                      style: t.bodySmall,
                    ),
                  ],
                ),
              ),
              if (pending)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: stateColor.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    stateLabel,
                    style: TextStyle(
                      color: stateColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          if (approved) ...[
            const SizedBox(height: AppSpacing.md),
            if (profile?['bank_name'] != null)
              KeyValueRow('Bank', profile!['bank_name'] as String),
            if (profile?['account_last4'] != null)
              KeyValueRow('Account', '•••• ${profile!['account_last4']}'),
            if (profile?['ifsc'] != null)
              KeyValueRow('IFSC', profile!['ifsc'] as String),
          ],
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: pending
                ? OutlinedButton.icon(
                    onPressed: () =>
                        context.push('/requests/${request!['id']}'),
                    icon: const AppIcon(Icons.receipt_long_outlined),
                    label: Text(
                      state == 'returned' ? 'Fix and resubmit' : 'View request',
                    ),
                  )
                : FilledButton.tonalIcon(
                    onPressed: () => context.push('/salary/bank-details'),
                    icon: AppIcon(
                      approved ? Icons.swap_horiz_rounded : Icons.add_rounded,
                    ),
                    label: Text(
                      approved ? 'Request account change' : 'Add bank details',
                    ),
                  ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            approved
                ? 'To protect payroll, approved details can only be changed through a new Admin-approved request.'
                : 'Attach a cancelled cheque, passbook or bank letter. Only the last four account digits are stored.',
            style: t.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  const _SummaryStat({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.salaryCard,
              borderRadius: BorderRadius.circular(10),
            ),
            child: AppIcon(icon, color: AppColors.salaryAction, size: 20),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _SalaryRow extends StatelessWidget {
  const _SalaryRow({
    required this.record,
    required this.currency,
    required this.onTap,
  });
  final Map<String, dynamic> record;
  final String currency;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final amount = record['net_amount'];
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: AppColors.salaryCard,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const AppIcon(
                Icons.receipt_long_outlined,
                color: AppColors.salaryAction,
                size: 22,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    monthLabel(record['salary_month']),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    'Payslip published',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Text(
              amount == null ? 'View' : money(amount, currency: currency),
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: amount == null ? AppColors.primary : AppColors.text,
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            const AppIcon(
              Icons.chevron_right_rounded,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

class _FloatingPanel extends StatelessWidget {
  const _FloatingPanel({required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: child,
          ),
        ),
    );
  }
}
