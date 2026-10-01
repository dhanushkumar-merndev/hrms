import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../home/home_providers.dart';
import 'attendance_day_screen.dart';
import 'attendance_screen.dart';

/// S09 — attendance correction (regularization). Proposes an effective
/// IN/OUT for a scheduled day; original punches are never changed.
class CorrectionScreen extends ConsumerStatefulWidget {
  const CorrectionScreen({super.key, this.date, this.editRequestId});
  final String? date;
  final String? editRequestId;

  @override
  ConsumerState<CorrectionScreen> createState() => _CorrectionScreenState();
}

class _CorrectionScreenState extends ConsumerState<CorrectionScreen> {
  late DateTime _date;
  TimeOfDay? _in;
  TimeOfDay? _out;
  bool _outNextDay = false;
  final _reason = TextEditingController();
  bool _busy = false;
  bool _loadingEdit = false;
  int? _expectedVersion;
  Map<String, String> _errors = const {};
  String? _error;
  final String _operationKey = ApiClient.newOperationKey();

  @override
  void initState() {
    super.initState();
    final parsed = widget.date == null || widget.date!.isEmpty ? null : DateTime.tryParse(widget.date!);
    _date = parsed ?? OrgTime.today();
    if (widget.editRequestId != null) _loadEdit();
  }

  Future<void> _loadEdit() async {
    setState(() => _loadingEdit = true);
    try {
      final req = (await ref.read(apiProvider).rpc('get_my_request', {'p_request_id': widget.editRequestId})).map;
      final revisions = (req['revisions'] as List).cast<Map>();
      final p = revisions.last['payload'] as Map;
      final inAt = OrgTime.local(OrgTime.parse(p['proposed_in_at'])!);
      final outAt = OrgTime.local(OrgTime.parse(p['proposed_out_at'])!);
      setState(() {
        _date = DateTime.parse(p['shift_date'] as String);
        _in = TimeOfDay(hour: inAt.hour, minute: inAt.minute);
        _out = TimeOfDay(hour: outAt.hour, minute: outAt.minute);
        _outNextDay = DateTime(outAt.year, outAt.month, outAt.day).isAfter(_date);
        _reason.text = (p['reason'] as String?) ?? '';
        _expectedVersion = (req['version'] as num).toInt();
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loadingEdit = false);
    }
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final today = OrgTime.today();
    final d = await showDatePicker(
      context: context,
      firstDate: today.subtract(const Duration(days: 90)),
      lastDate: today,
      initialDate: _date.isAfter(today) ? today : _date,
      helpText: 'Shift date',
    );
    if (d != null) setState(() => _date = d);
  }

  Future<void> _pickTime(bool isIn, Map<String, dynamic>? day) async {
    TimeOfDay initial = isIn ? const TimeOfDay(hour: 10, minute: 0) : const TimeOfDay(hour: 19, minute: 0);
    // Start from the recorded punch if there is one, else the shift time;
    // never suggest a check-out later than now (the server refuses that).
    final src = isIn ? (day?['effective_in_at'] ?? day?['start_at']) : (day?['effective_out_at'] ?? day?['end_at']);
    var parsed = OrgTime.parse(src);
    if (!isIn && parsed != null && parsed.isAfter(DateTime.now())) parsed = DateTime.now();
    if (parsed != null) {
      final l = OrgTime.local(parsed.toUtc());
      initial = TimeOfDay(hour: l.hour, minute: l.minute);
    }
    final t = await showTimePicker(context: context, initialTime: (isIn ? _in : _out) ?? initial);
    if (t != null) setState(() => isIn ? _in = t : _out = t);
  }

  Future<void> _submit() async {
    setState(() {
      _errors = const {};
      _error = null;
    });
    if (_in == null || _out == null || _reason.text.trim().length < 3) {
      setState(() => _errors = {
            if (_in == null) 'proposed_in_at': 'Choose a check-in time',
            if (_out == null) 'proposed_out_at': 'Choose a check-out time',
            if (_reason.text.trim().length < 3) 'reason': 'Explain the correction',
          });
      return;
    }
    final inAt = OrgTime.atLocal(_date, _in!.hour, _in!.minute);
    final outAt = OrgTime.atLocal(_date, _out!.hour, _out!.minute, addDays: _outNextDay ? 1 : 0);
    final ok = await confirm(context,
        title: 'Submit correction?',
        message: '${OrgTime.date(OrgTime.ymd(_date))}\n'
            'Check in ${_in!.format(context)} · Check out ${_out!.format(context)}${_outNextDay ? ' (next day)' : ''}\n\n'
            'Your approver will review it. You can edit it until they open it.',
        confirmLabel: 'Submit');
    if (!ok) return;
    setState(() => _busy = true);
    try {
      final res = await ref.read(apiProvider).rpc('save_correction_request', {
        'p_request_id': widget.editRequestId,
        'p_shift_date': OrgTime.ymd(_date),
        'p_proposed_in_at': inAt.toIso8601String(),
        'p_proposed_out_at': outAt.toIso8601String(),
        'p_reason': _reason.text.trim(),
        'p_submit': true,
        'p_expected_version': _expectedVersion,
        'p_operation_key': _operationKey,
      });
      ref.invalidate(homeSummaryProvider);
      ref.invalidate(myAttendanceProvider);
      if (!mounted) return;
      showMessage(context, 'Correction submitted.');
      context.pushReplacement('/requests/${res.map['id']}');
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _errors = e.fieldErrors;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final day = ref.watch(attendanceDayProvider((null, OrgTime.ymd(_date))));
    final d = day.value;
    return Scaffold(
      appBar: AppBar(title: Text(widget.editRequestId == null ? 'Request correction' : 'Edit correction')),
      body: _loadingEdit
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
              SectionCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event_outlined),
                    title: const Text('Shift date'),
                    subtitle: Text(OrgTime.date(OrgTime.ymd(_date))),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: widget.editRequestId == null ? _pickDate : null,
                  ),
                  if (d != null && d['scheduled'] == true)
                    Text(
                      'Shift ${OrgTime.time(d['start_at'])} – ${OrgTime.time(d['end_at'])} · recorded: '
                      '${d['effective_in_at'] == null ? 'no punches' : '${OrgTime.time(d['effective_in_at'])} – ${d['effective_out_at'] == null ? 'no check-out' : OrgTime.time(d['effective_out_at'])}'}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    )
                  else if (d != null)
                    const Text('No working shift is scheduled on this date.',
                        style: TextStyle(color: AppColors.error)),
                ]),
              ),
              // A correction sets both times and check-out cannot be in the
              // future, so an open day can only be fixed after checking out.
              if (d != null && d['effective_in_at'] != null && d['effective_out_at'] == null &&
                  OrgTime.ymd(_date) == OrgTime.ymd(OrgTime.today())) ...[
                const SizedBox(height: AppSpacing.md),
                SectionCard(
                  color: AppColors.warningSoft,
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.info_outline_rounded, color: AppColors.warning),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        'You are still checked in today. Check out first, then fix the check-in time here — '
                        'a correction needs both the check-in and check-out times.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.text),
                      ),
                    ),
                  ]),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              SectionCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _TimeField(
                    label: 'Check in',
                    value: _in?.format(context),
                    error: _errors['proposed_in_at'],
                    onTap: () => _pickTime(true, d),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _TimeField(
                    label: 'Check out',
                    value: _out == null ? null : '${_out!.format(context)}${_outNextDay ? ' (next day)' : ''}',
                    error: _errors['proposed_out_at'],
                    onTap: () => _pickTime(false, d),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _outNextDay,
                    onChanged: (v) => setState(() => _outNextDay = v),
                    title: const Text('Check-out is on the next day'),
                    subtitle: const Text('For overnight shifts'),
                  ),
                  TextField(
                    controller: _reason,
                    maxLength: 1000,
                    minLines: 3,
                    maxLines: 6,
                    decoration: InputDecoration(
                      labelText: 'Reason',
                      hintText: 'e.g. Phone battery died before check-out',
                      errorText: _errors['reason'],
                    ),
                  ),
                ]),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(_error!, style: const TextStyle(color: AppColors.error)),
              ],
              const SizedBox(height: AppSpacing.xl),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                    : const Text('Review & submit'),
              ),
              const SizedBox(height: AppSpacing.md),
              Text('A correction is recorded as an approved adjustment. Your original punches stay in the history.',
                  style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
            ]),
    );
  }
}

class _TimeField extends StatelessWidget {
  const _TimeField({required this.label, required this.value, required this.onTap, this.error});
  final String label;
  final String? value;
  final String? error;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, errorText: error, suffixIcon: const Icon(Icons.schedule_rounded)),
        child: Text(value ?? 'Choose time', style: TextStyle(color: value == null ? AppColors.textSecondary : AppColors.text)),
      ),
    );
  }
}
