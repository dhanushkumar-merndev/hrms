import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/format.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/paged_list.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/pickers.dart';
import '../../core/widgets/states.dart';
import '../files/file_service.dart';
import '../files/file_viewer_screen.dart';

/// S28 — payroll uploads (Admin, or HR with the explicit payroll grant).
/// Select employee -> salary month -> PDF (<= 5,000,000 bytes) -> the server
/// validates and hashes the stored copy -> preview -> publish. The employee
/// is notified only after publication; replacing needs a reason.
class PayrollUploadsScreen extends ConsumerStatefulWidget {
  const PayrollUploadsScreen({super.key, this.employeeId});
  final String? employeeId;

  @override
  ConsumerState<PayrollUploadsScreen> createState() => _PayrollUploadsScreenState();
}

class _PayrollUploadsScreenState extends ConsumerState<PayrollUploadsScreen> {
  Map<String, dynamic>? _employee;
  DateTime? _month;
  PlatformFile? _file;
  Uint8List? _bytes;
  String? _versionId;
  Map<String, dynamic>? _slip;
  bool _busy = false;
  String? _error;
  int _generation = 0;
  final _amount = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  ApiClient get _api => ref.read(apiProvider);

  @override
  void initState() {
    super.initState();
    if (widget.employeeId != null) _loadEmployee(widget.employeeId!);
  }

  Future<void> _loadEmployee(String id) async {
    try {
      final e = (await _api.rpc('get_employee', {'p_employee_id': id})).map;
      if (mounted) setState(() => _employee = e);
    } catch (_) {}
  }

  void _resetUpload() {
    _versionId = null;
    _slip = null;
    _error = null;
  }

  Future<void> _pickFile() async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['pdf']);
    if (picked.isEmpty) return;
    final f = picked.single;
    final bytes = await f.readAsBytes();
    setState(() {
      _resetUpload();
      if (bytes.isEmpty) {
        _error = 'The file is empty.';
      } else if (bytes.length > FileService.maxBytes) {
        _error = 'This file is ${formatBytes(bytes.length)}. Payslips must be at most 5 MB (5,000,000 bytes).';
      } else {
        _file = f;
        _bytes = bytes;
      }
    });
  }

  Future<Map<String, dynamic>?> _slipRow() async {
    final res = (await _api.rpc('list_payslip_uploads', {
      'p_employee_id': _employee!['id'],
      'p_salary_month': OrgTime.ymd(_month!),
      'p_limit': 1,
      'p_offset': 0,
    }))
        .map;
    final rows = (res['rows'] as List?) ?? const [];
    return rows.isEmpty ? null : (rows.first as Map).cast<String, dynamic>();
  }

  Future<void> _upload() async {
    if (_employee == null || _month == null || _bytes == null) {
      setState(() => _error = 'Choose the employee, salary month and PDF first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await ref.read(fileServiceProvider).upload(
            fileClass: 'payslip',
            bytes: _bytes!,
            filename: _file!.name,
            ownerEmployeeId: _employee!['id'] as String,
            salaryMonth: OrgTime.ymd(_month!),
          );
      final slip = await _slipRow();
      setState(() {
        _versionId = id;
        _slip = slip;
        _generation++;
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publish({required String versionId, required Map<String, dynamic> slip, required String who,
      required String month, String? amount}) async {
    final replacing = slip['current_file_version_id'] != null;
    String? reason;
    if (replacing) {
      reason = await askReason(context,
          title: 'Replace the published $month payslip?',
          message: 'The earlier version is kept for the audit history and archive. $who will see the new one.',
          confirmLabel: 'Publish replacement');
      if (reason == null) return;
    } else {
      final ok = await confirm(context,
          title: 'Publish $month payslip?',
          message: '$who will be notified and can view it in the app. Check the preview first.',
          confirmLabel: 'Publish');
      if (!ok) return;
    }
    setState(() => _busy = true);
    try {
      await _api.rpc('publish_payslip', {
        'p_file_version_id': versionId,
        'p_reason': reason,
        'p_expected_version': (slip['version'] as num?)?.toInt(),
      });
      final paid = num.tryParse((amount ?? '').replaceAll(',', '').trim());
      if (paid != null) {
        final emp = (slip['employee'] as Map?)?['id'] ?? _employee?['id'];
        await _api.rpc('set_payslip_amount',
            {'p_employee_id': emp, 'p_salary_month': slip['salary_month'] ?? OrgTime.ymd(_month!), 'p_net_amount': paid});
      }
      if (!mounted) return;
      showMessage(context, paid == null ? 'Published.' : 'Published with the amount paid.');
      _amount.clear();
      setState(() {
        _file = null;
        _bytes = null;
        _resetUpload();
        _generation++;
      });
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = _employee;
    final month = _month == null ? null : monthLabel(OrgTime.ymd(_month!));
    final who = e == null ? '' : '${e['name']} (${e['code']})';
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Payroll uploads'),
          bottom: const TabBar(tabs: [Tab(text: 'Upload'), Tab(text: 'History')]),
        ),
        body: PermissionGate(
          allowed: (s) => s.canManagePayroll,
          child: TabBarView(children: [
            ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
              FormSection(title: 'Upload a payslip', subtitle: 'PDF only, at most 5 MB. Nothing is sent to the employee '
                  'until you publish.', children: [
                PickerField(
                  label: 'Employee',
                  value: e == null ? null : who,
                  icon: Icons.person_search_outlined,
                  onTap: _busy
                      ? null
                      : () async {
                          final picked = await pickEmployee(context, status: 'all');
                          if (picked != null) {
                            setState(() {
                              _employee = picked;
                              _resetUpload();
                            });
                          }
                        },
                ),
                PickerField(
                  label: 'Salary month',
                  value: month,
                  icon: Icons.calendar_month_outlined,
                  onTap: _busy
                      ? null
                      : () async {
                          final m = await pickMonth(context, initial: _month);
                          if (m != null) {
                            setState(() {
                              _month = m;
                              _resetUpload();
                            });
                          }
                        },
                ),
                PickerField(
                  label: 'PDF file',
                  value: _file == null ? null : '${_file!.name} · ${formatBytes(_bytes!.length)}',
                  icon: Icons.attach_file_rounded,
                  onTap: _busy ? null : _pickFile,
                ),
                TextField(
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Amount paid this month (optional)',
                    prefixText: '₹ ',
                    helperText: 'Shown on the employee\'s salary card and added to their total received',
                  ),
                ),
                if (_error != null) Text(_error!, style: const TextStyle(color: AppColors.error)),
                if (_versionId == null)
                  FilledButton(
                    onPressed: _busy ? null : _upload,
                    child: _busy
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                        : const Text('Upload & check'),
                  )
                else ...[
                  const StatusChip('Checked: valid PDF, stored securely', tone: ChipTone.success,
                      icon: Icons.verified_outlined),
                  if (_slip?['current_file_version_id'] != null)
                    const StatusChip('A payslip is already published for this month', tone: ChipTone.warning),
                  OutlinedButton.icon(
                    onPressed: () => openProtectedFile(context, _versionId!, 'Preview · $month · ${e?['code']}'),
                    icon: const Icon(Icons.preview_outlined),
                    label: const Text('Preview'),
                  ),
                  FilledButton(
                    onPressed: _busy || _slip == null
                        ? null
                        : () => _publish(versionId: _versionId!, slip: _slip!, who: who, month: month!,
                            amount: _amount.text),
                    child: Text(_slip?['current_file_version_id'] == null ? 'Publish' : 'Publish replacement'),
                  ),
                ],
              ]),
            ]),
            PagedList<Map<String, dynamic>>(
              key: ValueKey('${e?['id']}|$_generation'),
              header: Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text(e == null ? 'All employees' : 'Uploads for ${e['name']}',
                    style: Theme.of(context).textTheme.titleSmall),
              ),
              fetch: (cursor) async {
                final offset = (cursor as int?) ?? 0;
                final res = (await _api.rpc('list_payslip_uploads', {
                  'p_employee_id': e?['id'],
                  'p_salary_month': null,
                  'p_limit': 25,
                  'p_offset': offset,
                }))
                    .map;
                return offsetPage(res, offset);
              },
              empty: const EmptyState(icon: Icons.receipt_long_outlined, title: 'No payslips uploaded yet'),
              itemBuilder: (context, row) => _UploadRow(
                row: row,
                busy: _busy,
                onPublish: (versionId) {
                  final emp = (row['employee'] as Map).cast<String, dynamic>();
                  _publish(
                    versionId: versionId,
                    slip: row,
                    who: '${emp['name']} (${emp['code']})',
                    month: monthLabel(row['salary_month']),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _UploadRow extends StatelessWidget {
  const _UploadRow({required this.row, required this.busy, required this.onPublish});
  final Map<String, dynamic> row;
  final bool busy;
  final ValueChanged<String> onPublish;

  @override
  Widget build(BuildContext context) {
    final emp = (row['employee'] as Map).cast<String, dynamic>();
    final versions = ((row['versions'] as List?) ?? const []).map((v) => (v as Map).cast<String, dynamic>()).toList();
    final month = monthLabel(row['salary_month']);
    return Card(
      child: ExpansionTile(
        shape: const Border(),
        title: Text('$month · ${emp['name']}'),
        subtitle: Text('${emp['code']} · ${row['current_file_version_id'] == null ? 'Not published' : 'Published'}'
            '${versions.length > 1 ? ' · ${versions.length} versions' : ''}'),
        children: [
          for (final v in versions)
            ListTile(
              dense: true,
              title: Text('Version ${v['version_no']} · ${v['filename'] ?? ''}'),
              subtitle: Text([
                _stateLabel(v['state'] as String?),
                if (v['size_bytes'] != null) formatBytes(v['size_bytes'] as num),
                OrgTime.dateTime(v['published_at'] ?? v['created_at']),
                if (v['validation_error'] != null) v['validation_error'],
                if (v['replace_reason'] != null) 'Reason: ${v['replace_reason']}',
              ].join(' · ')),
              trailing: v['state'] == 'validated'
                  ? TextButton(onPressed: busy ? null : () => onPublish(v['id'] as String), child: const Text('Publish'))
                  : null,
              onTap: const {'validated', 'published', 'superseded'}.contains(v['state'])
                  ? () => openProtectedFile(context, v['id'] as String, '$month · ${emp['code']} · v${v['version_no']}')
                  : null,
            ),
        ],
      ),
    );
  }

  static String _stateLabel(String? s) => switch (s) {
        'published' => 'Published',
        'validated' => 'Checked, not published',
        'superseded' => 'Replaced',
        'rejected' => 'Rejected',
        'deleted' || 'deletion_pending' => 'Archived locally',
        'requested' || 'quarantined' => 'Upload incomplete',
        _ => s ?? '',
      };
}
