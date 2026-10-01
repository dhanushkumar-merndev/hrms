import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/auth/session_controller.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/pickers.dart';
import '../../core/widgets/permission_gate.dart';
import '../people/people_screen.dart';

/// Shows a temporary password ONCE. It is never stored on the phone or the
/// server; closing this dialog is the last time anyone can see it.
Future<void> showTemporaryPassword(BuildContext context, {required String code, required String password}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      var acknowledged = false;
      return StatefulBuilder(builder: (ctx, setState) {
        return AlertDialog(
          title: const Text('Temporary password'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Give these to the employee in person. They must choose a new password when they first sign in.',
                style: Theme.of(ctx).textTheme.bodyMedium),
            const SizedBox(height: AppSpacing.md),
            KeyValueRow('Employee ID', code),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(color: AppColors.attendanceCard, borderRadius: BorderRadius.circular(12)),
              child: SelectableText(password,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: 1)),
            ),
            TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: password)),
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copy'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: acknowledged,
              onChanged: (v) => setState(() => acknowledged = v ?? false),
              title: const Text('I have noted it. It will not be shown again.'),
            ),
          ]),
          actions: [
            FilledButton(
              onPressed: acknowledged
                  ? () {
                      Clipboard.setData(const ClipboardData(text: ''));
                      Navigator.pop(ctx);
                    }
                  : null,
              child: const Text('Done'),
            ),
          ],
        );
      });
    },
  );
}

/// S27 — provision an employee (ID + temporary password). HR can create
/// Members and Managers; only an Admin can create HR or Admin accounts. A
/// retry after a lost response reuses the same operation id and never
/// creates a second login.
class EmployeeNewScreen extends ConsumerStatefulWidget {
  const EmployeeNewScreen({super.key});

  @override
  ConsumerState<EmployeeNewScreen> createState() => _EmployeeNewScreenState();
}

class _EmployeeNewScreenState extends ConsumerState<EmployeeNewScreen> {
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _designation = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  String? _departmentId;
  String? _teamId;
  String? _officeId;
  String? _shiftId;
  String _role = '';
  DateTime _join = OrgTime.today();
  Map<String, String> _errors = const {};
  String? _error;
  bool _busy = false;
  final String _operationId = ApiClient.newOperationKey();

  @override
  void dispose() {
    for (final c in [_code, _name, _designation, _email, _phone]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _suggestCode() async {
    try {
      final res = (await ref.read(apiProvider).rpc('list_employees',
              {'p_search': 'EMP', 'p_status': 'all', 'p_limit': 100, 'p_offset': 0}))
          .map;
      var max = 0;
      for (final e in (res['rows'] as List? ?? const [])) {
        final m = RegExp(r'^EMP(\d+)$').firstMatch((e as Map)['code'] as String? ?? '');
        if (m != null) max = [max, int.parse(m.group(1)!)].reduce((a, b) => a > b ? a : b);
      }
      _code.text = 'EMP${(max + 1).toString().padLeft(3, '0')}';
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _submit() async {
    final code = _code.text.trim().toUpperCase();
    final errors = <String, String>{
      if (!RegExp(r'^[A-Z0-9-]{3,32}$').hasMatch(code)) 'employee_code': '3–32 letters, digits or -',
      if (_name.text.trim().isEmpty) 'full_name': 'Required',
      if (_teamId == null) 'team_id': 'Choose a team',
      if (_officeId == null) 'office_id': 'Choose an office',
      if (_shiftId == null) 'shift_id': 'Choose a shift',
    };
    setState(() {
      _errors = errors;
      _error = errors.isEmpty ? null : 'Please check the highlighted fields.';
    });
    if (errors.isNotEmpty) return;
    setState(() => _busy = true);
    try {
      final res = (await ref.read(apiProvider).function('admin-users', {
        'action': 'provision',
        'operation_id': _operationId,
        'fields': {
          'employee_code': code,
          'full_name': _name.text.trim(),
          'designation': _designation.text.trim(),
          'department_id': _departmentId,
          'business_email': _email.text.trim(),
          'business_phone': _phone.text.trim(),
          'join_date': OrgTime.ymd(_join),
          'team_id': _teamId,
          'office_id': _officeId,
          'shift_id': _shiftId,
          'role': _role,
        },
      }))
          .map;
      if (!mounted) return;
      final password = res['temporary_password'] as String?;
      if (password != null) {
        await showTemporaryPassword(context, code: code, password: password);
      } else {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Already created'),
            content: const Text('This employee was created by an earlier attempt. Open their record and use '
                '"Reset password" to issue a new temporary password.'),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
          ),
        );
      }
      if (mounted) context.pushReplacement('/employees/${res['employee_id']}');
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
    final session = ref.watch(sessionContextProvider);
    final structure = ref.watch(orgStructureProvider).value;
    List<DropdownMenuItem<String>> items(String key) => [
          for (final x in structureList(structure, key).where((x) => x['active'] == true))
            DropdownMenuItem(value: x['id'] as String, child: Text(x['name'] as String)),
        ];
    final roles = [
      ('', 'Member'),
      ('manager', 'Manager'),
      if (session?.isAdmin ?? false) ...[('hr', 'HR'), ('admin', 'Admin')],
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Add employee')),
      body: PermissionGate(
        allowed: (s) => s.canProvision,
        child: ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
          FormSection(title: 'Login', subtitle: 'The employee ID is permanent and used to sign in.', children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: TextField(
                  controller: _code,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [LengthLimitingTextInputFormatter(32)],
                  decoration: InputDecoration(labelText: 'Employee ID', errorText: _errors['employee_code']),
                ),
              ),
              TextButton(onPressed: _suggestCode, child: const Text('Suggest')),
            ]),
            DropdownButtonFormField<String>(
              initialValue: _role,
              decoration: const InputDecoration(labelText: 'Role'),
              items: [for (final r in roles) DropdownMenuItem(value: r.$1, child: Text(r.$2))],
              onChanged: (v) => setState(() => _role = v ?? ''),
            ),
          ]),
          const SizedBox(height: AppSpacing.lg),
          FormSection(title: 'Employment', children: [
            TextField(controller: _name, maxLength: 200,
                decoration: InputDecoration(labelText: 'Full name', errorText: _errors['full_name'])),
            TextField(controller: _designation, maxLength: 120, decoration: const InputDecoration(labelText: 'Designation')),
            DropdownButtonFormField<String>(
              initialValue: _departmentId,
              decoration: InputDecoration(labelText: 'Department (optional)', errorText: _errors['department_id']),
              items: items('departments'),
              onChanged: (v) => setState(() => _departmentId = v),
            ),
            DateField(label: 'Joining date', date: _join, onChanged: (d) => setState(() => _join = d),
                error: _errors['join_date']),
          ]),
          const SizedBox(height: AppSpacing.lg),
          FormSection(title: 'Assignments', subtitle: 'All three are needed before the employee can punch.', children: [
            DropdownButtonFormField<String>(
              initialValue: _teamId,
              decoration: InputDecoration(labelText: 'Team', errorText: _errors['team_id']),
              items: items('teams'),
              onChanged: (v) => setState(() => _teamId = v),
            ),
            DropdownButtonFormField<String>(
              initialValue: _officeId,
              decoration: InputDecoration(labelText: 'Office', errorText: _errors['office_id']),
              items: items('offices'),
              onChanged: (v) => setState(() => _officeId = v),
            ),
            DropdownButtonFormField<String>(
              initialValue: _shiftId,
              decoration: InputDecoration(labelText: 'Shift', errorText: _errors['shift_id']),
              items: items('shifts'),
              onChanged: (v) => setState(() => _shiftId = v),
            ),
          ]),
          const SizedBox(height: AppSpacing.lg),
          FormSection(title: 'Work contact (optional)', children: [
            TextField(controller: _email, keyboardType: TextInputType.emailAddress, maxLength: 200,
                decoration: const InputDecoration(labelText: 'Work email')),
            TextField(controller: _phone, keyboardType: TextInputType.phone, maxLength: 40,
                decoration: const InputDecoration(labelText: 'Work phone')),
          ]),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            Semantics(liveRegion: true, child: Text(_error!, style: const TextStyle(color: AppColors.error))),
          ],
          const SizedBox(height: AppSpacing.xl),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                : const Text('Create employee'),
          ),
        ]),
      ),
    );
  }
}
