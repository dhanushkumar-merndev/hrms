import '../../core/widgets/app_icon.dart';
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../files/file_service.dart';
import '../home/home_providers.dart';
import '../requests/my_requests_screen.dart';
import 'leave_screen.dart';

final leaveTypesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  cacheFor(ref, const Duration(minutes: 15));
  return (await ref.read(apiProvider).rpc('list_leave_types', {'p_include_inactive': false})).list;
});

/// S12 — apply for (or edit) leave. The server counts working days, checks
/// balance and conflicts; the preview shows the exact result before submit.
class LeaveApplyScreen extends ConsumerStatefulWidget {
  const LeaveApplyScreen({super.key, this.editRequestId});
  final String? editRequestId;

  @override
  ConsumerState<LeaveApplyScreen> createState() => _LeaveApplyScreenState();
}

class _LeaveApplyScreenState extends ConsumerState<LeaveApplyScreen> {
  String? _typeId;
  DateTime? _start;
  DateTime? _end;
  String _startSlot = 'FULL';
  String _endSlot = 'FULL';
  final _reason = TextEditingController();
  String? _attachmentId;
  String? _attachmentName;
  int? _expectedVersion;
  Map<String, dynamic>? _preview;
  Map<String, String> _errors = const {};
  String? _error;
  bool _busy = false;
  bool _uploading = false;
  Timer? _debounce;
  int _previewSeq = 0;
  final String _operationKey = ApiClient.newOperationKey();

  bool get _single => _start != null && _end != null && _start == _end;

  @override
  void initState() {
    super.initState();
    if (widget.editRequestId != null) _loadEdit();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _loadEdit() async {
    try {
      final res = await ref.read(apiProvider).rpc('get_my_request', {'p_request_id': widget.editRequestId});
      final r = res.map;
      final p = ((r['revisions'] as List).last['payload'] as Map).cast<String, dynamic>();
      setState(() {
        _typeId = p['leave_type_id'] as String?;
        _start = DateTime.parse(p['start_date'] as String);
        _end = DateTime.parse(p['end_date'] as String);
        _startSlot = (p['start_slot'] as String?) ?? 'FULL';
        _endSlot = (p['end_slot'] as String?) ?? 'FULL';
        _reason.text = (p['reason'] as String?) ?? '';
        _attachmentId = p['attachment_file_version_id'] as String?;
        _attachmentName = _attachmentId == null ? null : 'Attached document';
        _expectedVersion = res.version;
      });
      _schedulePreview();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
  }

  void _schedulePreview() {
    _debounce?.cancel();
    if (_typeId == null || _start == null || _end == null) return;
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final seq = ++_previewSeq;
      try {
        final res = await ref.read(apiProvider).rpc('preview_leave', {
          'p_leave_type_id': _typeId,
          'p_start_date': OrgTime.ymd(_start!),
          'p_end_date': OrgTime.ymd(_end!),
          'p_start_slot': _startSlot,
          'p_end_slot': _single ? _startSlot : _endSlot,
        });
        if (seq == _previewSeq && mounted) setState(() => _preview = res.map); // ignore stale replies
      } on ApiException catch (e) {
        if (seq == _previewSeq && mounted) setState(() => _preview = {'valid': false, 'errors': {'start_date': e.message}});
      }
    });
  }

  Future<void> _pickDate(bool start) async {
    final today = OrgTime.today();
    final d = await showDatePicker(
      context: context,
      firstDate: today.subtract(const Duration(days: 60)),
      lastDate: today.add(const Duration(days: 400)),
      initialDate: (start ? _start : _end) ?? _start ?? today,
      helpText: start ? 'Start date' : 'End date',
    );
    if (d == null) return;
    setState(() {
      if (start) {
        _start = d;
        if (_end == null || _end!.isBefore(d)) _end = d;
      } else {
        _end = d;
      }
      if (!_single) {
        if (_startSlot == 'AM') _startSlot = 'FULL';
        if (_endSlot == 'PM') _endSlot = 'FULL';
      }
    });
    _schedulePreview();
  }

  void _setDay(DateTime d) {
    setState(() {
      _start = d;
      _end = d;
    });
    _schedulePreview();
  }

  Future<void> _attach(Map<String, dynamic>? type) async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
    );
    if (picked.isEmpty) return;
    final f = picked.single;
    setState(() => _uploading = true);
    try {
      final id = await ref.read(fileServiceProvider).upload(
            fileClass: type?['attachment_class'] == 'medical' ? 'medical_attachment' : 'leave_attachment',
            bytes: await f.readAsBytes(),
            filename: f.name,
          );
      setState(() {
        _attachmentId = id;
        _attachmentName = f.name;
      });
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _submit(Map<String, dynamic>? type) async {
    setState(() {
      _errors = const {};
      _error = null;
    });
    if (_typeId == null || _start == null || _end == null) {
      setState(() => _errors = {
            if (_typeId == null) 'leave_type_id': 'Choose a leave type',
            if (_start == null) 'start_date': 'Choose dates',
          });
      return;
    }
    final units = (_preview?['units'] as num?)?.toInt();
    final ok = await confirm(context,
        title: 'Submit leave?',
        message: '${type?['name'] ?? 'Leave'}: ${OrgTime.date(OrgTime.ymd(_start!))}'
            '${_single ? '' : ' – ${OrgTime.date(OrgTime.ymd(_end!))}'}'
            '${units == null ? '' : '\n${daysFromUnits(units)} working day(s)'}\n\n'
            'You can edit it until your approver opens it.',
        confirmLabel: 'Submit');
    if (!ok) return;
    setState(() => _busy = true);
    try {
      final res = await ref.read(apiProvider).rpc('save_leave_request', {
        'p_request_id': widget.editRequestId,
        'p_leave_type_id': _typeId,
        'p_start_date': OrgTime.ymd(_start!),
        'p_end_date': OrgTime.ymd(_end!),
        'p_start_slot': _startSlot,
        'p_end_slot': _single ? _startSlot : _endSlot,
        'p_reason': _reason.text.trim(),
        'p_attachment_file_version_id': _attachmentId,
        'p_submit': true,
        'p_expected_version': _expectedVersion,
        'p_operation_key': _operationKey,
      });
      ref.invalidate(leaveBalancesProvider);
      ref.invalidate(myRequestsProvider);
      ref.invalidate(homeSummaryProvider);
      if (!mounted) return;
      showMessage(context, 'Leave request submitted.');
      if (widget.editRequestId != null) {
        context.pop();
      } else {
        context.pushReplacement('/requests/${res.map['id']}');
      }
    } on ApiException catch (e) {
      // Keep everything the user entered; show the reason inline.
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
    final types = ref.watch(leaveTypesProvider);
    final balances = ref.watch(leaveBalancesProvider(null)).value;
    final typeList = types.value ?? const [];
    final type = typeList.where((t) => t['id'] == _typeId).firstOrNull;
    final balance = ((balances?['balances'] as List?) ?? const [])
        .cast<Map>()
        .where((b) => (b['leave_type'] as Map)['id'] == _typeId)
        .firstOrNull;
    final days = ((_preview?['days'] as List?) ?? const []).cast<Map>();
    final firstDay = days.isEmpty ? null : days.first;
    final previewErrors = ((_preview?['errors'] as Map?) ?? const {}).cast<String, dynamic>();
    final units = (_preview?['units'] as num?)?.toInt();
    final available = balance?['available_units'] as num?;

    String slotTimes(String slot) {
      if (firstDay == null) return '';
      return switch (slot) {
        'AM' => ' (${OrgTime.time(firstDay['start_at'])}–${OrgTime.time(firstDay['split_at'])})',
        'PM' => ' (${OrgTime.time(firstDay['split_at'])}–${OrgTime.time(firstDay['end_at'])})',
        _ => '',
      };
    }

    return Scaffold(
      appBar: AppBar(title: Text(widget.editRequestId == null ? 'Apply leave' : 'Edit leave')),
      body: ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
        SectionCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Leave type', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            for (final t in typeList) ...[
              _TypeOption(
                type: t,
                balance: ((balances?['balances'] as List?) ?? const [])
                    .cast<Map>()
                    .where((b) => (b['leave_type'] as Map)['id'] == t['id'])
                    .firstOrNull,
                selected: t['id'] == _typeId,
                onTap: () {
                  setState(() => _typeId = t['id'] as String);
                  _schedulePreview();
                },
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            if (_errors['leave_type_id'] != null)
              Text(_errors['leave_type_id']!, style: const TextStyle(color: AppColors.error, fontSize: 13)),
            if (types.hasError) const Text('Could not load leave types.', style: TextStyle(color: AppColors.error)),
            if (types.value?.isEmpty ?? false)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('No leave types are published yet. Contact HR.', style: TextStyle(color: AppColors.warning)),
              ),
            const SizedBox(height: AppSpacing.md),
            Text('When', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            Wrap(spacing: AppSpacing.sm, children: [
              for (final (label, offset) in const [('Today', 0), ('Tomorrow', 1)])
                ChoiceChip(
                  label: Text(label),
                  selected: _single && _start == OrgTime.today().add(Duration(days: offset)),
                  onSelected: (_) => _setDay(OrgTime.today().add(Duration(days: offset))),
                ),
            ]),
            const SizedBox(height: AppSpacing.md),
            Row(children: [
              Expanded(child: _DateField(label: 'From', date: _start, error: _errors['start_date'], onTap: () => _pickDate(true))),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: _DateField(label: 'To', date: _end, onTap: () => _pickDate(false))),
            ]),
            if (_start != null && (type == null || type['half_day_allowed'] == true)) ...[
              const SizedBox(height: AppSpacing.lg),
              if (_single)
                _SlotPicker(
                  label: 'Day part',
                  value: _startSlot,
                  options: [('FULL', 'Full day'), ('AM', 'First half${slotTimes('AM')}'), ('PM', 'Second half${slotTimes('PM')}')],
                  onChanged: (v) {
                    setState(() => _startSlot = v);
                    _schedulePreview();
                  },
                )
              else ...[
                _SlotPicker(
                  label: 'First day',
                  value: _startSlot,
                  options: [('FULL', 'Full day'), ('PM', 'From second half')],
                  onChanged: (v) {
                    setState(() => _startSlot = v);
                    _schedulePreview();
                  },
                ),
                _SlotPicker(
                  label: 'Last day',
                  value: _endSlot,
                  options: [('FULL', 'Full day'), ('AM', 'Until first half')],
                  onChanged: (v) {
                    setState(() => _endSlot = v);
                    _schedulePreview();
                  },
                ),
              ],
            ],
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _reason,
              maxLength: 1000,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(labelText: 'Reason (optional)'),
            ),
            if (type?['requires_attachment'] == true || _attachmentId != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const AppIcon(Icons.attach_file_rounded),
                title: Text(_attachmentName ?? 'Supporting document${type?['requires_attachment'] == true ? ' (required)' : ''}'),
                subtitle: Text(_errors['attachment'] ?? 'PDF, JPG or PNG up to 5 MB',
                    style: TextStyle(color: _errors['attachment'] != null ? AppColors.error : null)),
                trailing: _uploading
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : TextButton(onPressed: () => _attach(type), child: Text(_attachmentId == null ? 'Attach' : 'Replace')),
              ),
          ]),
        ),
        const SizedBox(height: AppSpacing.lg),
        if (_preview != null)
          SectionCard(
            color: previewErrors.isEmpty ? AppColors.leaveCard : AppColors.errorSoft,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (previewErrors.isNotEmpty)
                for (final e in previewErrors.values) Text('• $e', style: const TextStyle(color: AppColors.error))
              else ...[
                Text('${daysFromUnits(units)} working day(s)', style: Theme.of(context).textTheme.titleMedium),
                Text('Holidays and weekly offs are not counted.', style: Theme.of(context).textTheme.bodySmall),
                if (type?['paid'] == true && available != null && units != null)
                  Text('Balance after: ${daysFromUnits(available - units)} days',
                      style: TextStyle(color: available - units < 0 ? AppColors.error : AppColors.text)),
              ],
            ]),
          ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
          Semantics(liveRegion: true, child: Text(_error!, style: const TextStyle(color: AppColors.error))),
        ],
        const SizedBox(height: AppSpacing.xl),
        FilledButton(
          onPressed: _busy || _uploading ? null : () => _submit(type),
          child: _busy
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
              : const Text('Review & submit'),
        ),
      ]),
    );
  }
}

class _TypeOption extends StatelessWidget {
  const _TypeOption({required this.type, required this.balance, required this.selected, required this.onTap});
  final Map<String, dynamic> type;
  final Map? balance;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final paid = type['paid'] == true;
    final left = balance?['available_units'] as num?;
    final none = paid && left != null && left <= 0;
    final detail = !paid ? 'Unpaid' : left == null ? 'Paid' : '${daysFromUnits(left)} ${left == 2 ? 'day' : 'days'} left';
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
          decoration: BoxDecoration(
            color: selected ? AppColors.leaveCard : AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? AppColors.leaveAction : AppColors.border, width: selected ? 1.6 : 1),
          ),
          child: Row(children: [
            AppIcon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                color: selected ? AppColors.leaveAction : AppColors.textSecondary),
            const SizedBox(width: AppSpacing.md),
            Expanded(child: Text(type['name'] as String? ?? '', style: Theme.of(context).textTheme.titleSmall)),
            Text(detail,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: none ? AppColors.error : paid ? AppColors.leaveAction : AppColors.textSecondary)),
          ]),
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({required this.label, required this.date, required this.onTap, this.error});
  final String label;
  final DateTime? date;
  final VoidCallback onTap;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, errorText: error, suffixIcon: const AppIcon(Icons.event_outlined)),
        child: Text(date == null ? 'Choose' : OrgTime.date(OrgTime.ymd(date!), pattern: 'd MMM yyyy')),
      ),
    );
  }
}

class _SlotPicker extends StatelessWidget {
  const _SlotPicker({required this.label, required this.value, required this.options, required this.onChanged});
  final String label;
  final String value;
  final List<(String, String)> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
          for (final o in options)
            ChoiceChip(label: Text(o.$2), selected: value == o.$1, onSelected: (_) => onChanged(o.$1)),
        ]),
      ]),
    );
  }
}
