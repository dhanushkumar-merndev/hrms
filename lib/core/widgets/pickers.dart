import 'app_icon.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/theme.dart';
import '../api/api_client.dart';
import '../format.dart';
import '../time/org_time.dart';
import 'cards.dart';
import 'states.dart';

/// Tappable read-only field that opens a picker.
class PickerField extends StatelessWidget {
  const PickerField({super.key, required this.label, required this.value, required this.onTap, this.error, this.icon});
  final String label;
  final String? value;
  final VoidCallback? onTap;
  final String? error;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          errorText: error,
          suffixIcon: AppIcon(icon ?? Icons.arrow_drop_down_rounded),
          enabled: onTap != null,
        ),
        child: Text(value ?? 'Choose', style: TextStyle(color: value == null ? AppColors.textSecondary : AppColors.text)),
      ),
    );
  }
}

Future<DateTime?> pickDate(BuildContext context, {DateTime? initial, DateTime? first, DateTime? last, String? help}) {
  final today = OrgTime.today();
  final lo = first ?? DateTime(today.year - 10);
  final hi = last ?? DateTime(today.year + 3);
  var init = initial ?? today;
  if (init.isBefore(lo)) init = lo;
  if (init.isAfter(hi)) init = hi;
  return showDatePicker(context: context, firstDate: lo, lastDate: hi, initialDate: init, helpText: help);
}

class DateField extends StatelessWidget {
  const DateField({super.key, required this.label, required this.date, required this.onChanged, this.first, this.last, this.error});
  final String label;
  final DateTime? date;
  final ValueChanged<DateTime> onChanged;
  final DateTime? first;
  final DateTime? last;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return PickerField(
      label: label,
      error: error,
      icon: Icons.event_outlined,
      value: date == null ? null : DateFormat('d MMM yyyy').format(date!),
      onTap: () async {
        final d = await pickDate(context, initial: date, first: first, last: last, help: label);
        if (d != null) onChanged(d);
      },
    );
  }
}

/// Server time-of-day text ("HH:MM:SS") <-> TimeOfDay.
TimeOfDay? parseClock(Object? hms) {
  if (hms is! String || hms.length < 5) return null;
  return TimeOfDay(hour: int.tryParse(hms.substring(0, 2)) ?? 0, minute: int.tryParse(hms.substring(3, 5)) ?? 0);
}

String clockValue(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:00';

class TimeField extends StatelessWidget {
  const TimeField({super.key, required this.label, required this.time, required this.onChanged, this.error, this.onClear});
  final String label;
  final TimeOfDay? time;
  final ValueChanged<TimeOfDay> onChanged;
  final VoidCallback? onClear;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: PickerField(
          label: label,
          error: error,
          icon: Icons.schedule_rounded,
          value: time?.format(context),
          onTap: () async {
            final t = await showTimePicker(context: context, initialTime: time ?? const TimeOfDay(hour: 10, minute: 0));
            if (t != null) onChanged(t);
          },
        ),
      ),
      if (onClear != null && time != null)
        IconButton(tooltip: 'Clear $label', onPressed: onClear, icon: const AppIcon(Icons.close_rounded)),
    ]);
  }
}

/// Month grid with a year selector; months after [latest] are disabled.
Future<DateTime?> pickMonth(BuildContext context, {DateTime? initial, DateTime? latest, DateTime? earliest}) {
  final now = OrgTime.today();
  final max = latest ?? DateTime(now.year, now.month);
  final min = earliest ?? DateTime(max.year - 10);
  var year = (initial ?? max).year;
  return showDialog<DateTime>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
      return AlertDialog(
        title: Row(children: [
          IconButton(
            tooltip: 'Previous year',
            onPressed: year > min.year ? () => setState(() => year--) : null,
            icon: const AppIcon(Icons.chevron_left_rounded),
          ),
          Expanded(child: Text('$year', textAlign: TextAlign.center)),
          IconButton(
            tooltip: 'Next year',
            onPressed: year < max.year ? () => setState(() => year++) : null,
            icon: const AppIcon(Icons.chevron_right_rounded),
          ),
        ]),
        content: SizedBox(
          width: 320,
          child: Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
            for (var m = 1; m <= 12; m++)
              Builder(builder: (_) {
                final d = DateTime(year, m);
                final enabled = !d.isAfter(max) && !d.isBefore(DateTime(min.year, min.month));
                final selected = initial != null && initial.year == year && initial.month == m;
                return ChoiceChip(
                  label: SizedBox(width: 44, child: Text(DateFormat('MMM').format(d), textAlign: TextAlign.center)),
                  selected: selected,
                  onSelected: enabled ? (_) => Navigator.pop(ctx, d) : null,
                );
              }),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
      );
    }),
  );
}

/// Searchable employee chooser. [source] 'employees' uses the HR list
/// (HR/Admin only); 'reviewers' lists eligible Manager/HR/Admin approvers.
Future<Map<String, dynamic>?> pickEmployee(
  BuildContext context, {
  String title = 'Choose employee',
  String source = 'employees',
  String status = 'active',
  String? excludeId,
}) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _EmployeePicker(title: title, source: source, status: status, excludeId: excludeId),
  );
}

class _EmployeePicker extends ConsumerStatefulWidget {
  const _EmployeePicker({required this.title, required this.source, required this.status, this.excludeId});
  final String title;
  final String source;
  final String status;
  final String? excludeId;

  @override
  ConsumerState<_EmployeePicker> createState() => _EmployeePickerState();
}

class _EmployeePickerState extends ConsumerState<_EmployeePicker> {
  final _query = TextEditingController();
  Timer? _debounce;
  int _seq = 0;
  List<Map<String, dynamic>>? _rows;
  List<Map<String, dynamic>>? _all;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    final q = _query.text.trim();
    try {
      List<Map<String, dynamic>> rows;
      if (widget.source == 'reviewers') {
        _all ??= (await ref.read(apiProvider).rpc('list_reviewer_candidates')).list;
        final lower = q.toLowerCase();
        rows = _all!
            .where((e) => q.isEmpty ||
                (e['name'] as String).toLowerCase().contains(lower) ||
                (e['code'] as String).toLowerCase().startsWith(lower))
            .toList();
      } else {
        final res = await ref.read(apiProvider).rpc('list_employees', {
          'p_search': q.isEmpty ? null : q,
          'p_status': widget.status,
          'p_limit': 50,
          'p_offset': 0,
        });
        rows = ((res.map['rows'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
      }
      if (!mounted || seq != _seq) return;
      setState(() {
        _rows = rows.where((e) => e['id'] != widget.excludeId).toList();
        _error = null;
      });
    } catch (e) {
      if (mounted && seq == _seq) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.lg, AppSpacing.page, AppSpacing.sm),
            child: Row(children: [
              Expanded(child: Text(widget.title, style: Theme.of(context).textTheme.titleMedium)),
              IconButton(tooltip: 'Close', onPressed: () => Navigator.pop(context), icon: const AppIcon(Icons.close_rounded)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
            child: TextField(
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(prefixIcon: AppIcon(Icons.search_rounded), hintText: 'Name or employee ID'),
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), _load);
              },
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: _error != null
                ? ErrorState(error: _error!, onRetry: _load)
                : rows == null
                    ? const SkeletonList()
                    : rows.isEmpty
                        ? const EmptyState(icon: Icons.person_search_outlined, title: 'No matching people')
                        : ListView.builder(
                            itemCount: rows.length,
                            itemBuilder: (context, i) {
                              final e = rows[i];
                              final roles = ((e['roles'] as List?) ?? const []).cast<String>();
                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: AppColors.peopleCard,
                                  child: Text(initialsOf(e['name'] as String?),
                                      style: const TextStyle(color: AppColors.peopleAction, fontWeight: FontWeight.w700)),
                                ),
                                title: Text(e['name'] as String? ?? ''),
                                subtitle: Text([
                                  e['code'],
                                  if (roles.isNotEmpty) roles.map(roleLabel).join(', '),
                                  if (e['status'] != null && e['status'] != 'active') e['status'],
                                ].join(' · ')),
                                onTap: () => Navigator.pop(context, e),
                              );
                            },
                          ),
          ),
        ]),
      ),
    );
  }
}

/// Small labelled section used by long admin forms.
class FormSection extends StatelessWidget {
  const FormSection({super.key, required this.title, required this.children, this.subtitle});
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: AppSpacing.md),
        for (var i = 0; i < children.length; i++) ...[
          children[i],
          if (i < children.length - 1) const SizedBox(height: AppSpacing.md),
        ],
      ]),
    );
  }
}
