import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/info_button.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/states.dart';

final outsideWorkProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await ref.read(apiProvider).rpc('list_outside_work', {'p_from': null});
  return res.list.map((e) => (e as Map).cast<String, dynamic>()).toList();
});

/// Admin sends people on outside work: those days count as a full working
/// day without checking in or out.
class OutsideWorkScreen extends ConsumerWidget {
  const OutsideWorkScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(outsideWorkProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Outside work'), actions: const [
        Padding(
          padding: EdgeInsets.only(right: AppSpacing.page),
          child: InfoButton(
            size: 40,
            title: 'Outside work',
            message: 'Send people to work outside the office (client visit, site work, events).\n\n'
                'On those days they do not check in or out. Each working day counts as a full shift.\n\n'
                'If someone checks in anyway, their real punches are used instead.\n\n'
                'Remove a day any time with a reason; it then stops counting.',
          ),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final ok = await Navigator.of(context)
              .push<bool>(MaterialPageRoute(builder: (_) => const _GrantOutsideWork()));
          if (ok == true) ref.invalidate(outsideWorkProvider);
        },
        icon: const AppIcon(Icons.work_outline_rounded),
        label: const Text('Send people out'),
      ),
      body: PermissionGate(
        allowed: (s) => s.isAdmin,
        child: AsyncView(
          value: data,
          onRetry: () => ref.invalidate(outsideWorkProvider),
          isEmpty: (rows) => rows.isEmpty,
          empty: const EmptyState(
            icon: Icons.work_outline_rounded,
            title: 'No outside work',
            message: 'Tap "Send people out" to mark people working outside the office.',
          ),
          builder: (rows) => ListView(
            padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.page, AppSpacing.page, 96),
            children: [
              for (final r in rows)
                Card(
                  margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: ListTile(
                    title: Text((r['employee'] as Map)['name'] as String),
                    subtitle: Text('${OrgTime.date(r['work_date'] as String)} · ${r['reason']}',
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () async {
                        final reason = await askReason(
                          context,
                          title: 'Remove this outside work day?',
                          message: 'The day stops counting as worked unless they check in.',
                          confirmLabel: 'Remove',
                        );
                        if (reason == null) return;
                        try {
                          await ref.read(apiProvider).rpc('revoke_outside_work', {'p_id': r['id'], 'p_reason': reason});
                          ref.invalidate(outsideWorkProvider);
                          if (context.mounted) showMessage(context, 'Removed.');
                        } on ApiException catch (e) {
                          if (context.mounted) showMessage(context, e.message, error: true);
                        }
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GrantOutsideWork extends ConsumerStatefulWidget {
  const _GrantOutsideWork();

  @override
  ConsumerState<_GrantOutsideWork> createState() => _GrantOutsideWorkState();
}

class _GrantOutsideWorkState extends ConsumerState<_GrantOutsideWork> {
  List<Map<String, dynamic>>? _people;
  final _picked = <String>{};
  String _query = '';
  DateTimeRange? _range;
  static const _reasons = ['Videography', 'Work from home', 'Meeting', 'Client visit', 'Other'];
  String? _kind;
  final _reason = TextEditingController();

  String get _reasonText => _kind == 'Other' ? _reason.text.trim() : (_kind ?? '');
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  // Server pages at 100; small companies load in one or two calls.
  Future<void> _load() async {
    try {
      final rows = <Map<String, dynamic>>[];
      for (var offset = 0; offset < 1000; offset += 100) {
        final res = await ref.read(apiProvider).rpc('list_employees', {
          'p_search': null,
          'p_status': 'active',
          'p_limit': 100,
          'p_offset': offset,
        });
        final page = ((res.map['rows'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
        rows.addAll(page);
        if (page.length < 100) break;
      }
      if (mounted) setState(() => _people = rows);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _pickDates() async {
    final today = OrgTime.today();
    final r = await showDateRangePicker(
      context: context,
      firstDate: today.subtract(const Duration(days: 60)),
      lastDate: today.add(const Duration(days: 365)),
      initialDateRange: _range ?? DateTimeRange(start: today, end: today),
      helpText: 'Outside work days',
    );
    if (r != null) setState(() => _range = r);
  }

  Future<void> _save() async {
    final range = _range;
    if (_picked.isEmpty || range == null || _reasonText.isEmpty) {
      setState(() => _error = 'Choose people, dates and a reason.');
      return;
    }
    if (range.duration.inDays > 30) {
      setState(() => _error = 'Pick up to 31 days at a time.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(apiProvider).rpc('grant_outside_work', {
        'p_employee_ids': _picked.toList(),
        'p_from': OrgTime.ymd(range.start),
        'p_to': OrgTime.ymd(range.end),
        'p_reason': _reasonText,
      });
      if (!mounted) return;
      showMessage(context, '${res.map['days_added']} day(s) marked as outside work.');
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;
    final range = _range;
    return Scaffold(
      appBar: AppBar(title: const Text('Send people out')),
      body: ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
        SectionCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('When', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton.icon(
              onPressed: _pickDates,
              icon: const AppIcon(Icons.date_range_rounded, size: 20),
              label: Text(range == null
                  ? 'Choose days'
                  : range.start == range.end
                      ? OrgTime.date(OrgTime.ymd(range.start))
                      : '${OrgTime.date(OrgTime.ymd(range.start))} – ${OrgTime.date(OrgTime.ymd(range.end))}'),
            ),
            const SizedBox(height: AppSpacing.md),
            Text('Reason', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
              for (final r in _reasons)
                ChoiceChip(
                  label: Text(r),
                  selected: _kind == r,
                  onSelected: (_) => setState(() => _kind = r),
                ),
            ]),
            if (_kind == 'Other') ...[
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _reason,
                maxLength: 500,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Type the reason', hintText: 'Site survey, event…'),
              ),
            ],
          ]),
        ),
        const SizedBox(height: AppSpacing.md),
        SectionCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: Text('People · ${_picked.length} selected', style: Theme.of(context).textTheme.titleSmall),
              ),
              if (_picked.isNotEmpty)
                TextButton(onPressed: () => setState(_picked.clear), child: const Text('Clear')),
            ]),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search name or ID',
                isDense: true,
              ),
            ),
            if (_picked.isNotEmpty && people != null) ...[
              const SizedBox(height: AppSpacing.sm),
              // Selected people stay visible while searching.
              SizedBox(
                height: 40,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final p in people.where((p) => _picked.contains(p['id'])))
                    Padding(
                      padding: const EdgeInsets.only(right: AppSpacing.xs),
                      child: InputChip(
                        label: Text(p['name'] as String? ?? ''),
                        onDeleted: () => setState(() => _picked.remove(p['id'])),
                      ),
                    ),
                ]),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            if (people == null && _error == null)
              const Padding(padding: EdgeInsets.all(AppSpacing.lg), child: Center(child: CircularProgressIndicator()))
            else
              Builder(builder: (context) {
                final shown = (people ?? const <Map<String, dynamic>>[])
                    .where((p) =>
                        _query.isEmpty ||
                        (p['name'] as String? ?? '').toLowerCase().contains(_query) ||
                        (p['code'] as String? ?? '').toLowerCase().contains(_query))
                    .toList();
                final allShownPicked = shown.isNotEmpty && shown.every((p) => _picked.contains(p['id']));
                return Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.border),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(children: [
                    CheckboxListTile(
                      dense: true,
                      value: allShownPicked,
                      onChanged: shown.isEmpty
                          ? null
                          : (v) => setState(() => v == true
                              ? _picked.addAll(shown.map((p) => p['id'] as String))
                              : _picked.removeAll(shown.map((p) => p['id']))),
                      title: Text(_query.isEmpty ? 'Select everyone (${shown.length})' : 'Select all matches (${shown.length})',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                    const Divider(height: 1),
                    // Fixed height: the list scrolls inside, the page stays short.
                    SizedBox(
                      height: 320,
                      child: shown.isEmpty
                          ? const Center(child: Text('No one matches'))
                          : ListView.builder(
                              itemCount: shown.length,
                              itemBuilder: (context, i) {
                                final p = shown[i];
                                return CheckboxListTile(
                                  dense: true,
                                  value: _picked.contains(p['id']),
                                  onChanged: (v) => setState(
                                      () => v == true ? _picked.add(p['id'] as String) : _picked.remove(p['id'])),
                                  title: Text(p['name'] as String? ?? ''),
                                  subtitle: Text(p['code'] as String? ?? ''),
                                  controlAffinity: ListTileControlAffinity.leading,
                                );
                              },
                            ),
                    ),
                  ]),
                );
              }),
          ]),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
          Text(_error!, style: const TextStyle(color: AppColors.error)),
        ],
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.sm, AppSpacing.page, AppSpacing.md),
          child: FilledButton(
            onPressed: _busy ? null : _save,
            child: _busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                : Text(_picked.isEmpty ? 'Mark as outside work' : 'Mark ${_picked.length} as outside work'),
          ),
        ),
      ),
    );
  }
}
