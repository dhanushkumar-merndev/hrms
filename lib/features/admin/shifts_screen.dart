import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/auth/session_controller.dart';
import '../../core/format.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/pickers.dart';
import '../../core/widgets/states.dart';
import '../people/people_screen.dart';

final shiftsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  return (await ref.read(apiProvider).rpc('list_shifts')).list;
});

int _minutesOf(TimeOfDay t) => t.hour * 60 + t.minute;

/// Paid shift length in minutes (overnight wraps; equal times are invalid).
int shiftLengthMinutes(TimeOfDay start, TimeOfDay end) {
  final d = (_minutesOf(end) - _minutesOf(start)) % 1440;
  return d == 0 ? 1440 : d;
}

String _hm(int minutes) => OrgTime.hm(minutes * 60);

/// S30 — shifts with immutable published versions. HR (policy drafting) and
/// Admin save drafts; only Admin publishes, and changes apply from tomorrow
/// or later so recorded days keep the rules they were worked under.
class ShiftsScreen extends ConsumerWidget {
  const ShiftsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(shiftsProvider);
    final isAdmin = ref.watch(sessionContextProvider)?.isAdmin ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Shifts')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, null, null),
        icon: const AppIcon(Icons.add_rounded),
        label: const Text('New shift'),
      ),
      body: PermissionGate(
        allowed: (s) => s.canMasterData || s.canDraftPolicy,
        child: AsyncView(
          value: data,
          onRetry: () => ref.invalidate(shiftsProvider),
          isEmpty: (rows) => rows.isEmpty,
          empty: const EmptyState(icon: Icons.schedule_rounded, title: 'No shifts yet'),
          builder: (rows) => ListView(padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.page, AppSpacing.page, 96), children: [
            for (final s in rows) _ShiftCard(shift: s, isAdmin: isAdmin, onEdit: (base) => _edit(context, ref, s, base)),
          ]),
        ),
      ),
    );
  }

  static Future<void> _edit(BuildContext context, WidgetRef ref, Map<String, dynamic>? shift, Map<String, dynamic>? base) async {
    final saved = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => ShiftEditor(shift: shift, base: base)));
    if (saved == true) {
      ref.invalidate(shiftsProvider);
      ref.invalidate(orgStructureProvider);
    }
  }
}

class _ShiftCard extends ConsumerWidget {
  const _ShiftCard({required this.shift, required this.isAdmin, required this.onEdit});
  final Map<String, dynamic> shift;
  final bool isAdmin;
  final void Function(Map<String, dynamic>? base) onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final versions = ((shift['versions'] as List?) ?? const []).map((v) => (v as Map).cast<String, dynamic>()).toList();
    final draft = versions.where((v) => v['state'] == 'draft').firstOrNull;
    final published = versions.where((v) => v['state'] == 'published').toList();
    final current = published.isEmpty ? null : published.first;
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(shift['name'] as String, style: Theme.of(context).textTheme.titleSmall)),
            Text('${shift['assigned_count']} assigned', style: Theme.of(context).textTheme.bodySmall),
          ]),
          const SizedBox(height: AppSpacing.sm),
          if (current == null)
            const StatusChip('Not published yet — nobody can punch on it', tone: ChipTone.warning)
          else
            _VersionSummary(v: current, label: 'Published v${current['version_no']}'),
          if (draft != null) ...[
            const Divider(height: AppSpacing.xl),
            _VersionSummary(v: draft, label: 'Draft v${draft['version_no']}'),
            const SizedBox(height: AppSpacing.sm),
            Wrap(spacing: AppSpacing.sm, children: [
              OutlinedButton(onPressed: () => onEdit(draft), child: const Text('Edit draft')),
              if (isAdmin)
                FilledButton(
                  onPressed: () async {
                    final ok = await confirm(context,
                        title: 'Publish ${shift['name']} v${draft['version_no']}?',
                        message: 'It applies from ${OrgTime.date(draft['effective_from'] as String?)} to everyone on this '
                            'shift. Days already recorded keep the rules they were worked under.',
                        confirmLabel: 'Publish');
                    if (!ok) return;
                    try {
                      await ref.read(apiProvider).rpc('publish_shift_version', {'p_version_id': draft['id']});
                      ref.invalidate(shiftsProvider);
                      if (context.mounted) showMessage(context, 'Shift published.');
                    } on ApiException catch (e) {
                      if (context.mounted) showMessage(context, e.message, error: true);
                    }
                  },
                  child: const Text('Publish'),
                ),
            ]),
          ] else ...[
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton(onPressed: () => onEdit(current), child: const Text('Plan a change (new version)')),
          ],
          if (published.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text('${published.length - 1} earlier version(s) kept for history.',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
        ]),
      ),
    );
  }
}

class _VersionSummary extends StatelessWidget {
  const _VersionSummary({required this.v, required this.label});
  final Map<String, dynamic> v;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ext = v['checkout_extension_enabled'] == true ? (v['checkout_extension_seconds'] as num) ~/ 60 : 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('$label · from ${OrgTime.date(v['effective_from'] as String?)}', style: Theme.of(context).textTheme.bodySmall),
      Text('${clockLabel(v['start_local'])}–${clockLabel(v['end_local'])}${v['crosses_midnight'] == true ? ' (next day)' : ''}'
          ' · ${OrgTime.hm(v['expected_seconds'] as num?)} · ${weekdaysLabel((v['weekly_mask'] as num).toInt())}'),
      Text('Grace ${(v['grace_seconds'] as num) ~/ 60} min · '
          '${v['lunch_start_local'] == null ? 'lunch included (time not set)' : 'paid lunch ${clockLabel(v['lunch_start_local'])}–${clockLabel(v['lunch_end_local'])}'}'
          ' · ${ext > 0 ? 'checkout up to $ext min late' : 'no checkout extension'}',
          style: Theme.of(context).textTheme.bodyMedium),
    ]);
  }
}

class ShiftEditor extends ConsumerStatefulWidget {
  const ShiftEditor({super.key, this.shift, this.base});
  final Map<String, dynamic>? shift;
  final Map<String, dynamic>? base;

  @override
  ConsumerState<ShiftEditor> createState() => _ShiftEditorState();
}

class _ShiftEditorState extends ConsumerState<ShiftEditor> {
  late final Map<String, dynamic> b = widget.base ?? const {};
  late final _name = TextEditingController(text: widget.shift?['name'] as String?);
  late TimeOfDay _start = parseClock(b['start_local']) ?? const TimeOfDay(hour: 10, minute: 0);
  late TimeOfDay _end = parseClock(b['end_local']) ?? const TimeOfDay(hour: 19, minute: 0);
  late TimeOfDay? _lunchStart = parseClock(b['lunch_start_local']);
  late TimeOfDay? _lunchEnd = parseClock(b['lunch_end_local']);
  late int _mask = (b['weekly_mask'] as num?)?.toInt() ?? 31;
  late final _grace = TextEditingController(text: '${((b['grace_seconds'] as num?) ?? 1800) ~/ 60}');
  late final _early = TextEditingController(text: '${((b['early_entry_seconds'] as num?) ?? 1800) ~/ 60}');
  late bool _earlyCredit = b['early_credit'] == true;
  late bool _extension = b['checkout_extension_enabled'] as bool? ?? true;
  late final _extMinutes = TextEditingController(text: '${((b['checkout_extension_seconds'] as num?) ?? 7200) ~/ 60}');
  late DateTime _from = _defaultFrom();
  Map<String, String> _errors = const {};
  String? _error;
  bool _busy = false;

  DateTime _defaultFrom() {
    final today = OrgTime.today();
    final published = ((widget.shift?['versions'] as List?) ?? const []).any((v) => (v as Map)['state'] == 'published');
    if (b['state'] == 'draft' && b['effective_from'] != null) return DateTime.parse(b['effective_from'] as String);
    return published ? today.add(const Duration(days: 1)) : today;
  }

  @override
  void dispose() {
    for (final c in [_name, _grace, _early, _extMinutes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
      _errors = const {};
    });
    try {
      await ref.read(apiProvider).rpc('save_shift_draft', {
        'p_shift_id': widget.shift?['id'],
        'p_name': _name.text.trim(),
        'p_effective_from': OrgTime.ymd(_from),
        'p_start_local': clockValue(_start),
        'p_end_local': clockValue(_end),
        'p_weekly_mask': _mask,
        'p_grace_seconds': (int.tryParse(_grace.text.trim()) ?? 0) * 60,
        'p_lunch_start_local': _lunchStart == null ? null : clockValue(_lunchStart!),
        'p_lunch_end_local': _lunchEnd == null ? null : clockValue(_lunchEnd!),
        'p_early_entry_seconds': (int.tryParse(_early.text.trim()) ?? 0) * 60,
        'p_early_credit': _earlyCredit,
        'p_checkout_extension_enabled': _extension,
        'p_checkout_extension_seconds': (int.tryParse(_extMinutes.text.trim()) ?? 0) * 60,
      });
      if (mounted) Navigator.pop(context, true);
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
    final length = _start == _end ? 0 : shiftLengthMinutes(_start, _end);
    final grace = int.tryParse(_grace.text.trim()) ?? 0;
    final ext = _extension ? (int.tryParse(_extMinutes.text.trim()) ?? 0) : 0;
    final overnight = _minutesOf(_end) <= _minutesOf(_start);
    return Scaffold(
      appBar: AppBar(title: Text(widget.shift == null ? 'New shift' : 'Shift draft')),
      body: ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
        FormSection(title: 'Shift', children: [
          if (widget.shift == null)
            TextField(controller: _name, maxLength: 80,
                decoration: InputDecoration(labelText: 'Shift name', errorText: _errors['name'])),
          DateField(label: 'Effective from', date: _from, error: _errors['effective_from'],
              onChanged: (d) => setState(() => _from = d)),
          TimeField(label: 'Starts', time: _start, onChanged: (t) => setState(() => _start = t)),
          TimeField(label: 'Ends${overnight ? ' (next day)' : ''}', time: _end, error: _errors['end_local'],
              onChanged: (t) => setState(() => _end = t)),
          Text('Working days', style: Theme.of(context).textTheme.bodySmall),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (var i = 0; i < 7; i++)
              FilterChip(
                label: Text(weekdayShort[i]),
                selected: _mask & (1 << i) != 0,
                onSelected: (on) => setState(() => _mask = on ? _mask | (1 << i) : _mask & ~(1 << i)),
              ),
          ]),
          if (_errors['weekly_mask'] != null) Text(_errors['weekly_mask']!, style: const TextStyle(color: AppColors.error)),
        ]),
        const SizedBox(height: AppSpacing.lg),
        FormSection(title: 'Paid lunch', subtitle: 'Lunch is paid and included in the shift; no punch is needed.', children: [
          TimeField(label: 'Lunch starts', time: _lunchStart, error: _errors['lunch'],
              onChanged: (t) => setState(() => _lunchStart = t), onClear: () => setState(() => _lunchStart = null)),
          TimeField(label: 'Lunch ends', time: _lunchEnd,
              onChanged: (t) => setState(() => _lunchEnd = t), onClear: () => setState(() => _lunchEnd = null)),
        ]),
        const SizedBox(height: AppSpacing.lg),
        FormSection(title: 'Rules', children: [
          TextField(controller: _grace, keyboardType: TextInputType.number, onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: 'Late grace (minutes)', errorText: _errors['grace_seconds'],
                  helperText: 'Only decides the "late" label; it never adds worked time.')),
          TextField(controller: _early, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Check-in opens early by (minutes)')),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _earlyCredit,
            title: const Text('Credit time worked before the shift starts'),
            subtitle: const Text('Off by default: work is credited from the scheduled start.'),
            onChanged: (v) => setState(() => _earlyCredit = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _extension,
            title: const Text('Allow late checkout'),
            onChanged: (v) => setState(() => _extension = v),
          ),
          if (_extension)
            TextField(controller: _extMinutes, keyboardType: TextInputType.number, onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: 'Late checkout allowed for (minutes)',
                    errorText: _errors['checkout_extension_seconds'])),
        ]),
        const SizedBox(height: AppSpacing.lg),
        if (length > 0)
          SectionCard(
            color: AppColors.attendanceCard,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Expected: ${_hm(length)} per working day', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: AppSpacing.sm),
              Text('• On time for the full shift → worked ${_hm(length)}, short 0 min'),
              Text('• In $grace min late → worked ${_hm(length - grace)}, short ${_hm(grace)}, not marked late'),
              Text('• In ${grace + 1} min late → worked ${_hm(length - grace - 1)}, short ${_hm(grace + 1)}, marked late'),
              if (ext >= 30) Text('• In 30 min late, out 30 min late → worked ${_hm(length)}, short 0 min'),
              Text('• Half-day leave → ${_hm(length ~/ 2)} required for the other half'),
              const SizedBox(height: AppSpacing.xs),
              Text('Extra time is shown for information only and is not overtime pay.',
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
          Text(_error!, style: const TextStyle(color: AppColors.error)),
        ],
        const SizedBox(height: AppSpacing.xl),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
              : const Text('Save draft'),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text('Drafts do not affect anyone until an Admin publishes them.',
            textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}
