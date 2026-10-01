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
import '../../core/time/org_time.dart';
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
    if (_data != null && mounted) setState(() => _data = null);
  }

  Future<void> _toggle() async {
    if (_data != null) return _hide();
    setState(() => _busy = true);
    try {
      _confirming = true;
      final ok = await widget.auth.confirm(title: 'Show your salary', subtitle: 'Confirm it is you');
      _confirming = false;
      if (!ok) return;
      final res = await ref.read(apiProvider).rpc('get_my_salary');
      if (!mounted) return;
      setState(() => _data = res.map);
      _timer?.cancel();
      _timer = Timer(_autoHide, _hide);
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
    final currency = (profile?['currency'] as String?) ?? 'INR';
    final recent = ((d?['recent'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
    final name = ref.watch(sessionContextProvider)?.name;
    final t = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('My salary')),
      body: ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
        SalaryCard(revealed: revealed, profile: profile, holderFallback: name, busy: _busy, onTap: _toggle),
        const SizedBox(height: AppSpacing.lg),
        Row(children: [
          Expanded(
            child: _Stat(
              icon: Icons.savings_outlined,
              label: 'Received so far',
              value: revealed ? money(d['lifetime_paid'], currency: currency) : '₹ • • • •',
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: _Stat(
              icon: Icons.event_repeat_rounded,
              label: 'Months paid',
              value: revealed ? '${d['paid_months'] ?? 0}' : '• •',
            ),
          ),
        ]),
        const SizedBox(height: AppSpacing.lg),
        if (!revealed)
          SectionCard(
            color: AppColors.attendanceCard,
            child: Row(children: [
              const Icon(Icons.lock_outline_rounded, color: AppColors.primary),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  'Tap the card and confirm with your fingerprint to see your salary. '
                  'It hides again after a minute or when you leave the app.',
                  style: t.bodyMedium?.copyWith(color: AppColors.text),
                ),
              ),
            ]),
          )
        else if (profile == null)
          const SectionCard(
            child: Text('HR has not added your salary details yet. Ask HR if you think this is wrong.'),
          )
        else ...[
          SectionCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Salary account', style: t.titleSmall),
              const SizedBox(height: AppSpacing.sm),
              KeyValueRow('Bank', (profile['bank_name'] as String?) ?? '—'),
              KeyValueRow('Account', profile['account_last4'] == null ? '—' : 'Ending ${profile['account_last4']}'),
              KeyValueRow('IFSC', (profile['ifsc'] as String?) ?? '—'),
              if (profile['effective_from'] != null)
                KeyValueRow('Salary since', OrgTime.date(profile['effective_from'] as String?, pattern: 'd MMM yyyy')),
            ]),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('Recent salary', style: t.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          if (recent.isEmpty)
            Text('No payslips published yet.', style: t.bodyMedium)
          else
            for (final r in recent)
              Container(
                margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
                ),
                child: Row(children: [
                  const Icon(Icons.receipt_long_outlined, color: AppColors.salaryAction),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(child: Text(monthLabel(r['salary_month']), style: t.titleSmall)),
                  Text(r['net_amount'] == null ? 'Payslip only' : money(r['net_amount'], currency: currency),
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: r['net_amount'] == null ? AppColors.textSecondary : AppColors.text)),
                ]),
              ),
        ],
        const SizedBox(height: AppSpacing.md),
        OutlinedButton.icon(
          onPressed: () => context.push('/payslips'),
          icon: const Icon(Icons.picture_as_pdf_outlined),
          label: const Text('Open payslips'),
        ),
        const SizedBox(height: AppSpacing.md),
        Text('Amounts are entered by HR. This app does not calculate salary or tax.',
            textAlign: TextAlign.center, style: t.bodySmall),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: AppColors.salaryCard, borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: AppColors.salaryAction, size: 20),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 2),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: Text(value,
              key: ValueKey(value),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.text)),
        ),
      ]),
    );
  }
}
