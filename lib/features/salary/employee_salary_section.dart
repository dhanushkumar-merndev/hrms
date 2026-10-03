import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/device/device_key.dart';
import '../../core/device/local_auth.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/pickers.dart';
import 'salary_widgets.dart';

/// Payroll staff's view of one employee's salary and approved bank summary.
/// Salary can be edited here; bank details only change through an employee
/// request with immutable proof and approval.
class EmployeeSalarySection extends ConsumerStatefulWidget {
  const EmployeeSalarySection({
    super.key,
    required this.employeeId,
    required this.employeeName,
    this.auth = const LocalAuth(),
  });
  final String employeeId;
  final String employeeName;
  final LocalAuth auth;

  @override
  ConsumerState<EmployeeSalarySection> createState() =>
      _EmployeeSalarySectionState();
}

class _EmployeeSalarySectionState extends ConsumerState<EmployeeSalarySection> {
  Map<String, dynamic>? _data;
  int _version = 0;
  bool _busy = false;
  late final AppLifecycleListener _lifecycle;
  bool _confirming = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () {
        if (!_confirming && _data != null && mounted) {
          setState(() => _data = null);
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _load({bool confirmFirst = true}) async {
    setState(() => _busy = true);
    try {
      if (confirmFirst) {
        _confirming = true;
        final ok = await widget.auth.confirm(
          title: 'Show salary',
          subtitle: widget.employeeName,
        );
        _confirming = false;
        if (!ok) return;
      }
      final res = await ref.read(apiProvider).rpc('get_employee_salary', {
        'p_employee_id': widget.employeeId,
      });
      if (!mounted) return;
      setState(() {
        _data = res.map;
        _version = res.version ?? 0;
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

  Future<void> _edit() async {
    final profile =
        (_data?['profile'] as Map?)?.cast<String, dynamic>() ?? const {};
    final saved = await showSalaryEditor(
      context,
      ref,
      employeeId: widget.employeeId,
      employeeName: widget.employeeName,
      profile: profile,
      version: _version,
    );
    if (saved) await _load(confirmFirst: false);
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final profile = (d?['profile'] as Map?)?.cast<String, dynamic>();
    final revisions = ((d?['revisions'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    final t = Theme.of(context).textTheme;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Salary', style: t.titleSmall)),
              if (d != null && d['can_edit'] == true)
                TextButton(
                  onPressed: _busy ? null : _edit,
                  child: Text(profile == null ? 'Add' : 'Edit'),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          SalaryCard(
            compact: true,
            revealed: d != null,
            profile: profile,
            holderFallback: widget.employeeName,
            busy: _busy,
            onTap: () => d == null ? _load() : setState(() => _data = null),
          ),
          if (d != null) ...[
            const SizedBox(height: AppSpacing.md),
            KeyValueRow(
              'Received so far',
              money(
                d['lifetime_paid'],
                currency: (profile?['currency'] as String?) ?? 'INR',
              ),
            ),
            if (profile?['effective_from'] != null)
              KeyValueRow(
                'Effective from',
                OrgTime.date(
                  profile!['effective_from'] as String?,
                  pattern: 'd MMM yyyy',
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
            Text('Approved bank account', style: t.titleSmall),
            KeyValueRow('Bank', (profile?['bank_name'] as String?) ?? '—'),
            KeyValueRow(
              'Account',
              profile?['account_last4'] == null
                  ? '—'
                  : '•••• ${profile!['account_last4']}',
            ),
            KeyValueRow('IFSC', (profile?['ifsc'] as String?) ?? '—'),
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                'The employee submits bank proof. HR/Admin approval is required; later changes require Admin.',
                style: t.bodySmall,
              ),
            ),
            if (d['can_edit'] != true)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(
                  'Your own salary is changed by an Admin.',
                  style: t.bodySmall,
                ),
              ),
            if (revisions.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Text('Changes', style: t.titleSmall),
              for (final r in revisions)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${money(r['monthly_salary'], currency: r['currency'] as String? ?? 'INR')} from '
                    '${OrgTime.date(r['effective_from'] as String?, pattern: 'd MMM yyyy')}'
                    '${r['reason'] != null ? ' · ${r['reason']}' : ''} · by ${r['created_by'] ?? '—'}',
                    style: t.bodySmall,
                  ),
                ),
            ],
          ] else
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text(
                'Tap the card to view. Changes are recorded in the audit history.',
                style: t.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

/// Add/edit salary only. Bank details use the employee approval workflow.
Future<bool> showSalaryEditor(
  BuildContext context,
  WidgetRef ref, {
  required String employeeId,
  required String employeeName,
  required Map<String, dynamic> profile,
  required int version,
}) async {
  final amount = TextEditingController(text: _plain(profile['monthly_salary']));
  final reason = TextEditingController();
  DateTime? from = DateTime.tryParse(
    (profile['effective_from'] as String?) ?? '',
  );
  var busy = false;
  String? error;
  var fieldErrors = <String, String>{};
  final hadAmount = profile['monthly_salary'] != null;

  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        Future<void> save() async {
          setState(() {
            busy = true;
            error = null;
            fieldErrors = {};
          });
          try {
            await ref.read(apiProvider).rpc('set_employee_salary', {
              'p_employee_id': employeeId,
              'p_fields': {
                'monthly_salary': amount.text.replaceAll(',', '').trim(),
                'effective_from': from == null ? null : OrgTime.ymd(from!),
              },
              'p_reason': reason.text.trim(),
              'p_expected_version': version,
            });
            if (ctx.mounted) Navigator.pop(ctx, true);
          } on ApiException catch (e) {
            setState(() {
              busy = false;
              error = e.message;
              fieldErrors = e.fieldErrors;
            });
          }
        }

        InputDecoration dec(
          String label,
          String key, {
          String? helper,
          String? prefix,
        }) => InputDecoration(
          labelText: label,
          helperText: helper,
          prefixText: prefix,
          errorText: fieldErrors[key],
        );
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(AppSpacing.page),
            children: [
              Text(
                'Salary · $employeeName',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: amount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                decoration: dec(
                  'Monthly salary',
                  'monthly_salary',
                  prefix: '₹ ',
                  helper: 'Take-home per month',
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              DateField(
                label: 'Effective from',
                date: from,
                error: fieldErrors['effective_from'],
                onChanged: (d) => setState(() => from = d),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: reason,
                maxLength: 500,
                decoration: dec(
                  'Reason${hadAmount ? ' (needed if the amount changes)' : ' (optional)'}',
                  'reason',
                ),
              ),
              if (error != null)
                Text(error!, style: const TextStyle(color: AppColors.error)),
              const SizedBox(height: AppSpacing.md),
              FilledButton(
                onPressed: busy ? null : save,
                child: busy
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : const Text('Save'),
              ),
            ],
          ),
        );
      },
    ),
  );
  for (final c in [amount, reason]) {
    c.dispose();
  }
  return saved ?? false;
}

String _plain(Object? v) {
  if (v == null) return '';
  final n = v is num ? v : num.tryParse('$v');
  if (n == null) return '';
  return n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(2);
}
