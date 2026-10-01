import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/auth/session_controller.dart';
import '../../core/files/save_file.dart';
import '../../core/files/xlsx.dart';
import '../../core/files/xlsx_reader.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/pill_tabs.dart';
import '../people/people_screen.dart';
import 'employee_import.dart';

/// S-IMP — add or update employees from an Excel sheet. The file is picked
/// with the phone's file picker (Google Drive, Downloads, WhatsApp files …),
/// read on the phone, checked and shown as a preview. Nothing is saved until
/// "Import" is pressed; every row then goes through the normal server checks.
class EmployeeImportScreen extends ConsumerStatefulWidget {
  const EmployeeImportScreen({super.key});

  @override
  ConsumerState<EmployeeImportScreen> createState() => _EmployeeImportScreenState();
}

enum _Filter { all, changes, problems }

class _EmployeeImportScreenState extends ConsumerState<EmployeeImportScreen> {
  String? _filename;
  List<SheetData> _sheets = const [];
  int _sheetIndex = 0;
  ImportPlan? _plan;
  Map<String, Map<String, dynamic>> _existing = const {};
  bool _busy = false;
  String? _error;
  _Filter _filter = _Filter.all;
  int _done = 0;
  bool _imported = false;
  final _results = <int, String>{}; // row number -> outcome text
  final _failed = <int>{};
  final _passwords = <(String, String, String)>[]; // code, name, password

  ApiClient get _api => ref.read(apiProvider);

  Future<void> _downloadTemplate() async {
    try {
      final structure = await ref.read(orgStructureProvider.future);
      final bytes = buildXlsx(importTemplate(structure));
      final saved = await saveBytesAs(bytes, 'employee_import_template.xlsx',
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      if (saved && mounted) showMessage(context, 'Template saved. Fill it in, then choose it here.');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<Map<String, Map<String, dynamic>>> _loadExisting() async {
    final all = <String, Map<String, dynamic>>{};
    var offset = 0;
    while (true) {
      final res = (await _api.rpc('list_employees', {'p_status': 'all', 'p_limit': 100, 'p_offset': offset})).map;
      final rows = ((res['rows'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
      for (final r in rows) {
        all[(r['code'] as String).toUpperCase()] = r;
      }
      offset += rows.length;
      if (rows.isEmpty || offset >= ((res['total'] as num?)?.toInt() ?? 0)) break;
    }
    return all;
  }

  Future<void> _pick() async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['xlsx', 'csv']);
    if (picked.isEmpty) return;
    final f = picked.single;
    setState(() {
      _busy = true;
      _error = null;
      _plan = null;
      _imported = false;
      _results.clear();
      _failed.clear();
      _passwords.clear();
    });
    try {
      final bytes = await f.readAsBytes();
      final sheets = SpreadsheetReader.read(bytes, f.name);
      _existing = await _loadExisting();
      // Prefer a sheet named like "Employees", else the first sheet.
      final idx = sheets.indexWhere((s) => s.name.toLowerCase().contains('employee'));
      setState(() {
        _filename = f.name;
        _sheets = sheets;
        _sheetIndex = idx < 0 ? 0 : idx;
      });
      await _replan();
    } on SpreadsheetException catch (e) {
      setState(() => _error = e.message);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _replan() async {
    final s = ref.read(sessionContextProvider)!;
    final structure = await ref.read(orgStructureProvider.future);
    setState(() => _plan = planImport(
          _sheets[_sheetIndex],
          existing: _existing,
          structure: structure,
          isAdmin: s.isAdmin,
          canProvision: s.canProvision,
          canManagePayroll: s.canManagePayroll,
          myEmployeeId: s.employeeId,
        ));
  }

  Future<void> _import() async {
    final plan = _plan!;
    final rows = plan.actionable;
    final creates = plan.count(ImportKind.create);
    final ok = await confirm(context,
        title: 'Import ${rows.length} ${rows.length == 1 ? 'row' : 'rows'}?',
        message: '${creates > 0 ? '$creates new ${creates == 1 ? 'account' : 'accounts'} will be created with temporary passwords. ' : ''}'
            '${plan.count(ImportKind.update)} existing ${plan.count(ImportKind.update) == 1 ? 'person' : 'people'} will be updated. '
            'Rows with problems are skipped. Every change is recorded in the audit history.',
        confirmLabel: 'Import');
    if (!ok) return;
    setState(() {
      _busy = true;
      _done = 0;
    });
    for (final r in rows) {
      try {
        _results[r.rowNumber] = await _apply(r);
      } on ApiException catch (e) {
        _failed.add(r.rowNumber);
        final fields = e.fieldErrors.values.join('; ');
        _results[r.rowNumber] = fields.isEmpty ? e.message : '${e.message} ($fields)';
      } catch (e) {
        _failed.add(r.rowNumber);
        _results[r.rowNumber] = 'Failed: $e';
      }
      if (!mounted) return;
      setState(() => _done++);
    }
    ref.invalidate(orgStructureProvider);
    setState(() {
      _busy = false;
      _imported = true;
    });
  }

  Future<String> _apply(ImportRow r) async {
    final notes = <String>[];
    if (r.kind == ImportKind.create) {
      final res = (await _api.function('admin-users', {
        'action': 'provision',
        'operation_id': ApiClient.newOperationKey(),
        'fields': {
          'employee_code': r.code,
          'full_name': r.values['name'],
          'designation': r.values['designation'],
          'department_id': r.departmentId,
          'business_email': r.values['email'],
          'business_phone': r.values['phone'],
          'join_date': r.values['join_date'],
          'team_id': r.teamId,
          'office_id': r.officeId,
          'shift_id': r.shiftId,
          'role': r.role == 'member' ? null : r.role,
        },
      }))
          .map;
      final id = res['employee_id'] as String;
      final password = res['temporary_password'] as String?;
      if (password != null) _passwords.add((r.code, r.name, password));
      notes.add('Account created');
      if (r.salary.isNotEmpty) {
        await _api.rpc('set_employee_salary',
            {'p_employee_id': id, 'p_fields': r.salary, 'p_reason': 'Excel import', 'p_expected_version': 0});
        notes.add('salary saved');
      }
      return notes.join(', ');
    }
    final id = r.existing!['id'] as String;
    if (r.patch.isNotEmpty) {
      final current = await _api.rpc('get_employee', {'p_employee_id': id});
      await _api.rpc('update_employee', {'p_employee_id': id, 'p_patch': r.patch, 'p_expected_version': current.version});
      notes.add('Details updated');
    }
    if (r.salary.isNotEmpty) {
      final current = await _api.rpc('get_employee_salary', {'p_employee_id': id});
      await _api.rpc('set_employee_salary', {
        'p_employee_id': id,
        'p_fields': r.salary,
        'p_reason': 'Excel import',
        'p_expected_version': current.version ?? 0,
      });
      notes.add('salary saved');
    }
    return notes.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final t = Theme.of(context).textTheme;
    final visible = plan == null
        ? const <ImportRow>[]
        : plan.rows.where((r) => switch (_filter) {
              _Filter.all => true,
              _Filter.changes => r.kind == ImportKind.create || r.kind == ImportKind.update,
              _Filter.problems => r.kind == ImportKind.error || _failed.contains(r.rowNumber),
            }).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Import from Excel')),
      bottomNavigationBar: plan == null || plan.actionable.isEmpty || _imported
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.sm, AppSpacing.page, AppSpacing.md),
                child: FilledButton.icon(
                  onPressed: _busy ? null : _import,
                  icon: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                      : const AppIcon(Icons.cloud_upload_outlined),
                  label: Text(_busy
                      ? 'Importing $_done of ${plan.actionable.length}…'
                      : 'Import ${plan.actionable.length} ${plan.actionable.length == 1 ? 'row' : 'rows'}'),
                ),
              ),
            ),
      body: PermissionGate(
        allowed: (s) => s.canProvision || s.canManagePayroll || s.canMasterData,
        child: ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
          // Step 1: file
          SectionCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(color: AppColors.approvalsCard, borderRadius: BorderRadius.circular(14)),
                  child: const AppIcon(Icons.table_view_rounded, color: AppColors.approvalsAction),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_filename ?? 'Choose an Excel file', style: t.titleSmall),
                    Text(
                      _filename == null
                          ? 'From Google Drive, Downloads or any app. .xlsx or .csv'
                          : '${_sheets.length} ${_sheets.length == 1 ? 'sheet' : 'sheets'} · nothing saved yet',
                      style: t.bodySmall,
                    ),
                  ]),
                ),
              ]),
              const SizedBox(height: AppSpacing.md),
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _pick,
                icon: const AppIcon(Icons.folder_open_rounded),
                label: Text(_filename == null ? 'Choose file' : 'Choose another file'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton.icon(
                onPressed: _busy ? null : _downloadTemplate,
                icon: const AppIcon(Icons.download_rounded),
                label: const Text('Download the template'),
              ),
              if (_busy && plan == null) const LinearProgressIndicator(),
              if (_error != null) Text(_error!, style: const TextStyle(color: AppColors.error)),
            ]),
          ),
          if (_sheets.length > 1) ...[
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<int>(
              icon: const AppIcon(Icons.keyboard_arrow_down_rounded),
              initialValue: _sheetIndex,
              decoration: const InputDecoration(labelText: 'Sheet'),
              items: [
                for (var i = 0; i < _sheets.length; i++)
                  DropdownMenuItem(value: i, child: Text('${_sheets[i].name} (${_sheets[i].rows.length} rows)')),
              ],
              onChanged: _busy
                  ? null
                  : (i) {
                      setState(() => _sheetIndex = i ?? 0);
                      _replan();
                    },
            ),
          ],
          if (plan != null) ...[
            const SizedBox(height: AppSpacing.lg),
            if (plan.missingColumns.isNotEmpty)
              SectionCard(
                color: AppColors.warningSoft,
                child: Text(
                  plan.rows.isEmpty && plan.missingColumns.contains('Employee ID')
                      ? 'No "Employee ID" column found in the first 10 rows. Use the template, or name a column "Employee ID".'
                      : 'Missing column${plan.missingColumns.length == 1 ? '' : 's'}: ${plan.missingColumns.join(', ')}. '
                          'Only existing employees can be updated.',
                  style: t.bodyMedium?.copyWith(color: AppColors.warning),
                ),
              ),
            if (_imported) _ImportSummary(results: _results, failed: _failed, passwords: _passwords),
            _Counts(plan: plan),
            if (plan.unknownHeaders.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text('Ignored columns: ${plan.unknownHeaders.join(', ')}', style: t.bodySmall),
            ],
            const SizedBox(height: AppSpacing.md),
            PillTabs<_Filter>(
              options: const [(_Filter.all, 'All'), (_Filter.changes, 'Changes'), (_Filter.problems, 'Problems')],
              value: _filter,
              onChanged: (v) => setState(() => _filter = v),
            ),
            const SizedBox(height: AppSpacing.md),
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Text('Nothing to show here.', textAlign: TextAlign.center, style: t.bodyMedium),
              ),
            for (final r in visible.take(300)) ...[
              _RowCard(row: r, result: _results[r.rowNumber], failed: _failed.contains(r.rowNumber)),
              const SizedBox(height: AppSpacing.sm),
            ],
            if (visible.length > 300) Text('Showing the first 300 rows.', style: t.bodySmall),
            const SizedBox(height: 80),
          ],
        ]),
      ),
    );
  }
}

class _Counts extends StatelessWidget {
  const _Counts({required this.plan});
  final ImportPlan plan;

  @override
  Widget build(BuildContext context) {
    Widget tile(String label, int n, Color bg, Color fg, IconData icon) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
            child: Column(children: [
              AppIcon(icon, color: fg, size: 20),
              const SizedBox(height: 4),
              Text('$n', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: fg)),
              Text(label, style: TextStyle(fontSize: 12, color: fg, fontWeight: FontWeight.w600)),
            ]),
          ),
        );
    return Row(children: [
      tile('New', plan.count(ImportKind.create), AppColors.successSoft, AppColors.success, Icons.person_add_alt_1_rounded),
      const SizedBox(width: AppSpacing.sm),
      tile('Update', plan.count(ImportKind.update), AppColors.attendanceCard, AppColors.primary, Icons.edit_note_rounded),
      const SizedBox(width: AppSpacing.sm),
      tile('No change', plan.count(ImportKind.unchanged), AppColors.background, AppColors.textSecondary, Icons.check_rounded),
      const SizedBox(width: AppSpacing.sm),
      tile('Problems', plan.count(ImportKind.error), AppColors.errorSoft, AppColors.error, Icons.error_outline_rounded),
    ]);
  }
}

class _RowCard extends StatelessWidget {
  const _RowCard({required this.row, this.result, this.failed = false});
  final ImportRow row;
  final String? result;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final (label, tone) = switch (row.kind) {
      ImportKind.create => ('New', ChipTone.success),
      ImportKind.update => ('Update', ChipTone.info),
      ImportKind.unchanged => ('No change', ChipTone.neutral),
      ImportKind.error => ('Problem', ChipTone.error),
    };
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
        border: Border.all(color: row.kind == ImportKind.error || failed ? AppColors.error.withValues(alpha: 0.4) : AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('${row.code.isEmpty ? '—' : row.code} · ${row.name.isEmpty ? 'No name' : row.name}',
                style: t.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          StatusChip(label, tone: tone),
        ]),
        Text('Row ${row.rowNumber}', style: t.bodySmall),
        for (final e in row.errors) _line(Icons.error_outline_rounded, e, AppColors.error),
        for (final c in row.changes) _line(Icons.arrow_right_alt_rounded, c, AppColors.text),
        for (final n in row.notes) _line(Icons.info_outline_rounded, n, AppColors.textSecondary),
        if (result != null) _line(failed ? Icons.cancel_outlined : Icons.check_circle_outline_rounded, result!,
            failed ? AppColors.error : AppColors.success),
      ]),
    );
  }

  static Widget _line(IconData icon, String text, Color color) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AppIcon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: TextStyle(fontSize: 13, color: color))),
        ]),
      );
}

class _ImportSummary extends StatelessWidget {
  const _ImportSummary({required this.results, required this.failed, required this.passwords});
  final Map<int, String> results;
  final Set<int> failed;
  final List<(String, String, String)> passwords;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final okCount = results.length - failed.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: SectionCard(
        color: failed.isEmpty ? AppColors.successSoft : AppColors.warningSoft,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Imported $okCount of ${results.length}${failed.isEmpty ? '' : ' · ${failed.length} failed (see Problems)'}',
              style: t.titleSmall),
          if (passwords.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text('Temporary passwords — shown only now. Give each person theirs; they set a new one at first sign-in.',
                style: t.bodySmall?.copyWith(color: AppColors.text)),
            const SizedBox(height: AppSpacing.sm),
            for (final (code, name, password) in passwords)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('$code · $name', style: t.titleSmall),
                      SelectableText(password, style: const TextStyle(fontFamily: 'monospace', fontSize: 15)),
                    ]),
                  ),
                  IconButton(
                    tooltip: 'Copy',
                    icon: const AppIcon(Icons.copy_rounded),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: password));
                      showMessage(context, 'Copied $code password.');
                    },
                  ),
                ]),
              ),
          ],
        ]),
      ),
    );
  }
}
