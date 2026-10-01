import '../../core/files/xlsx.dart';
import '../../core/files/xlsx_reader.dart';

/// Column keys the import understands, with the header spellings accepted
/// for each (case and punctuation ignored).
const importColumns = <String, List<String>>{
  'code': ['employee id', 'employee code', 'emp id', 'code', 'id'],
  'name': ['full name', 'name', 'employee name'],
  'role': ['role'],
  'designation': ['designation', 'title', 'job title'],
  'department': ['department', 'dept'],
  'team': ['team'],
  'office': ['office', 'location'],
  'shift': ['shift'],
  'join_date': [
    'join date',
    'joining date',
    'date of joining',
    'doj',
    'joined',
  ],
  'email': ['work email', 'email', 'business email'],
  'phone': ['work phone', 'phone', 'mobile', 'business phone'],
  'salary': ['monthly salary', 'salary', 'monthly salary inr', 'net salary'],
  'salary_from': ['salary effective from', 'effective from', 'salary from'],
  'bank': ['bank name', 'bank'],
  'holder': ['account holder', 'account holder name'],
  'account': ['account number', 'account no', 'bank account', 'account'],
  'ifsc': ['ifsc', 'ifsc code'],
};

/// Header row of the template (also the column order of the download).
const templateHeaders = [
  'Employee ID',
  'Full name',
  'Role',
  'Designation',
  'Department',
  'Team',
  'Office',
  'Shift',
  'Join date',
  'Work email',
  'Work phone',
  'Monthly salary',
  'Salary effective from',
];

enum ImportKind { create, update, unchanged, error }

class ImportRow {
  ImportRow(this.rowNumber, this.values);
  final int rowNumber;
  final Map<String, String> values;
  ImportKind kind = ImportKind.unchanged;
  final errors = <String>[];
  final notes = <String>[];
  final changes = <String>[];
  Map<String, dynamic>? existing;

  /// Resolved ids for a new employee.
  String? departmentId, teamId, officeId, shiftId;

  /// Fields for update_employee (existing employees).
  final patch = <String, dynamic>{};

  /// Fields for set_employee_salary (empty = no salary change).
  final salary = <String, dynamic>{};

  String get code => values['code'] ?? '';
  String get name => values['name']?.isNotEmpty == true
      ? values['name']!
      : (existing?['name'] as String? ?? '');
  String? get role => _role(values['role']);
}

class ImportPlan {
  ImportPlan(this.rows, this.missingColumns, this.unknownHeaders);
  final List<ImportRow> rows;
  final List<String> missingColumns;
  final List<String> unknownHeaders;
  int count(ImportKind k) => rows.where((r) => r.kind == k).length;
  List<ImportRow> get actionable => rows
      .where((r) => r.kind == ImportKind.create || r.kind == ImportKind.update)
      .toList();
}

String _norm(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

String? _role(String? raw) => switch (_norm(raw ?? '')) {
  '' || 'member' || 'employee' || 'staff' => 'member',
  'manager' || 'team manager' => 'manager',
  'hr' || 'human resources' => 'hr',
  'admin' || 'administrator' => 'admin',
  _ => null,
};

/// Builds the plan from a sheet. [existing] maps employee code -> the
/// employee card from list_employees (all statuses). [structure] is
/// list_org_structure. Nothing is written here.
ImportPlan planImport(
  SheetData sheet, {
  required Map<String, Map<String, dynamic>> existing,
  required Map<String, dynamic> structure,
  required bool isAdmin,
  required bool canProvision,
  required bool canManagePayroll,
  required String myEmployeeId,
}) {
  // Header row: the first of the top 10 rows that has an "Employee ID" column.
  var headerIndex = -1;
  final columns = <String, int>{};
  final unknown = <String>[];
  for (var i = 0; i < sheet.rows.length && i < 10 && headerIndex < 0; i++) {
    final found = <String, int>{};
    for (var c = 0; c < sheet.rows[i].length; c++) {
      final h = _norm(sheet.rows[i][c]);
      for (final e in importColumns.entries) {
        if (!found.containsKey(e.key) && e.value.contains(h)) found[e.key] = c;
      }
    }
    if (found.containsKey('code')) {
      headerIndex = i;
      columns.addAll(found);
      for (var c = 0; c < sheet.rows[i].length; c++) {
        final h = sheet.rows[i][c].trim();
        if (h.isNotEmpty && !found.containsValue(c)) unknown.add(h);
      }
    }
  }
  if (headerIndex < 0) return ImportPlan([], ['Employee ID'], []);

  List<Map<String, dynamic>> list(String k) =>
      ((structure[k] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
  final departments = list('departments');
  final teams = list('teams').where((t) => t['active'] != false).toList();
  final offices = list('offices').where((t) => t['active'] != false).toList();
  final shifts = list('shifts').where((t) => t['active'] != false).toList();
  String? lookup(List<Map<String, dynamic>> items, String raw) {
    final n = _norm(raw);
    return items
        .where((i) => _norm('${i['name']}') == n)
        .map((i) => i['id'] as String)
        .firstOrNull;
  }

  final rows = <ImportRow>[];
  final seen = <String>{};
  for (var i = headerIndex + 1; i < sheet.rows.length; i++) {
    final cells = sheet.rows[i];
    final values = <String, String>{
      for (final e in columns.entries)
        e.key: e.value < cells.length ? cells[e.value].trim() : '',
    };
    if (values.values.every((v) => v.isEmpty)) continue; // blank line
    final r = ImportRow(i + 1, values);
    rows.add(r);
    final code = values['code']!.toUpperCase().replaceAll(' ', '');
    values['code'] = code;
    if (!RegExp(r'^[A-Z0-9-]{3,32}$').hasMatch(code)) {
      r.errors.add('Employee ID must be 3–32 letters, digits or "-"');
    } else if (!seen.add(code)) {
      r.errors.add('Employee ID $code appears more than once in the file');
    }
    if (r.role == null)
      r.errors.add('Role must be Member, Manager, HR or Admin');

    // Salary columns (any filled -> salary update).
    final salaryText = (values['salary'] ?? '').replaceAll(
      RegExp(r'[₹,\s]|INR|Rs\.?', caseSensitive: false),
      '',
    );
    if (salaryText.isNotEmpty) {
      final amount = num.tryParse(salaryText);
      if (amount == null || amount < 0) {
        r.errors.add('Monthly salary "${values['salary']}" is not a number');
      } else {
        r.salary['monthly_salary'] = amount;
      }
    }
    if ((values['salary_from'] ?? '').isNotEmpty) {
      final d = SpreadsheetReader.date(values['salary_from']!);
      if (d == null) {
        r.errors.add(
          'Salary effective from "${values['salary_from']}" is not a date',
        );
      } else {
        r.salary['effective_from'] = d;
      }
    }
    if (const [
      'bank',
      'holder',
      'account',
      'ifsc',
    ].any((key) => (values[key] ?? '').isNotEmpty)) {
      r.notes.add(
        'Bank columns skipped: employees submit bank details with proof in My salary',
      );
    }
    if (r.salary.isNotEmpty && !canManagePayroll) {
      r.notes.add('Salary columns skipped: you do not have payroll access');
      r.salary.clear();
    }

    final current = existing[code];
    r.existing = current;
    if (current == null) {
      // New employee.
      if (!canProvision) r.errors.add('You cannot create employees');
      if ((values['name'] ?? '').isEmpty)
        r.errors.add('Full name is required for a new employee');
      final join = SpreadsheetReader.date(values['join_date'] ?? '');
      if (join == null) {
        r.errors.add(
          (values['join_date'] ?? '').isEmpty
              ? 'Join date is required for a new employee'
              : 'Join date "${values['join_date']}" is not a date (use 2026-10-01)',
        );
      } else {
        values['join_date'] = join;
      }
      if ((r.role == 'hr' || r.role == 'admin') && !isAdmin)
        r.errors.add('Only an Admin can create HR or Admin accounts');
      String? resolve(
        String key,
        String label,
        List<Map<String, dynamic>> items, {
        required bool required,
      }) {
        final raw = values[key] ?? '';
        if (raw.isEmpty) {
          if (items.length == 1)
            return items.single['id'] as String; // the only one
          if (required)
            r.errors.add(
              '$label is required (${items.map((i) => i['name']).join(', ')})',
            );
          return null;
        }
        final id = lookup(items, raw);
        if (id == null) {
          r.errors.add(
            'Unknown $label "$raw"${items.isEmpty ? '' : ' — use one of: ${items.map((i) => i['name']).join(', ')}'}',
          );
        }
        return id;
      }

      r.teamId = resolve('team', 'team', teams, required: true);
      r.officeId = resolve('office', 'office', offices, required: true);
      r.shiftId = resolve('shift', 'shift', shifts, required: true);
      if ((values['department'] ?? '').isNotEmpty)
        r.departmentId = resolve(
          'department',
          'department',
          departments,
          required: false,
        );
      if (r.errors.isEmpty) {
        r.kind = ImportKind.create;
        r.changes.add(
          'New ${r.role} account — a temporary password is created',
        );
        if (r.salary.isNotEmpty) r.changes.add('Salary details added');
      }
    } else {
      // Existing employee: details + salary only.
      void diff(
        String key,
        String field,
        String label,
        Object? now, {
        Object? value,
      }) {
        final raw = values[key] ?? '';
        if (raw.isEmpty) return;
        final next = value ?? raw;
        if ('${now ?? ''}'.trim() != '$next') {
          r.patch[field] = next;
          r.changes.add(
            '$label: ${now == null || '$now'.isEmpty ? '—' : now} → $raw',
          );
        }
      }

      diff('name', 'full_name', 'Name', current['name']);
      diff('designation', 'designation', 'Designation', current['designation']);
      diff('email', 'business_email', 'Work email', current['business_email']);
      diff('phone', 'business_phone', 'Work phone', current['business_phone']);
      if ((values['department'] ?? '').isNotEmpty) {
        final id = lookup(departments, values['department']!);
        if (id == null) {
          r.errors.add('Unknown department "${values['department']}"');
        } else if (id != (current['department'] as Map?)?['id']) {
          r.patch['department_id'] = id;
          r.changes.add(
            'Department: ${(current['department'] as Map?)?['name'] ?? '—'} → ${values['department']}',
          );
        }
      }
      final roles = ((current['roles'] as List?) ?? const []).cast<String>();
      final currentRole = roles.contains('admin')
          ? 'admin'
          : roles.contains('hr')
          ? 'hr'
          : roles.contains('manager')
          ? 'manager'
          : 'member';
      if ((values['role'] ?? '').isNotEmpty &&
          r.role != null &&
          r.role != currentRole) {
        r.notes.add(
          'Role not changed (${_title(currentRole)} → ${_title(r.role!)}): change roles on the employee page',
        );
      }
      final team = (current['team'] as Map?)?['name'];
      if ((values['team'] ?? '').isNotEmpty &&
          _norm(values['team']!) != _norm('${team ?? ''}')) {
        r.notes.add(
          'Team not changed: move people between teams on the employee page (it needs a start date)',
        );
      }
      if ((values['office'] ?? '').isNotEmpty ||
          (values['shift'] ?? '').isNotEmpty) {
        r.notes.add('Office and shift are changed on the employee page');
      }
      if (r.salary.isNotEmpty) {
        if (current['id'] == myEmployeeId && !isAdmin) {
          r.notes.add('Your own salary is changed by an Admin — skipped');
          r.salary.clear();
        } else {
          r.changes.add(
            'Salary details updated (${r.salary.keys.map(_salaryLabel).join(', ')})',
          );
        }
      }
      if (r.errors.isEmpty)
        r.kind = (r.patch.isEmpty && r.salary.isEmpty)
            ? ImportKind.unchanged
            : ImportKind.update;
    }
    if (r.errors.isNotEmpty) r.kind = ImportKind.error;
  }

  final missing = <String>[
    if (!columns.containsKey('name')) 'Full name',
    if (!columns.containsKey('join_date')) 'Join date',
  ];
  return ImportPlan(rows, missing, unknown);
}

String _title(String role) =>
    role == 'hr' ? 'HR' : '${role[0].toUpperCase()}${role.substring(1)}';
String _salaryLabel(Object k) => switch (k) {
  'monthly_salary' => 'amount',
  'effective_from' => 'effective date',
  _ => '$k'.toUpperCase(),
};

/// The downloadable template: an Employees sheet with the header row and
/// an Instructions sheet listing the valid names for this organisation.
List<XlsxSheet> importTemplate(Map<String, dynamic> structure) {
  List<String> names(String k) => ((structure[k] as List?) ?? const [])
      .map((e) => '${(e as Map)['name']}')
      .toList();
  final sheet = XlsxSheet(
    'Employees',
    columnWidths: [14, 24, 12, 20, 18, 18, 16, 14, 14, 26, 16, 16, 20],
  )..header(templateHeaders);
  final help = XlsxSheet('Instructions', columnWidths: [26, 90])
    ..header(['Column', 'How to fill it'])
    ..add([
      'Employee ID',
      'Required. 3–32 letters/digits/-, e.g. VG004. An existing ID updates that person.',
    ])
    ..add(['Full name', 'Required for new people.'])
    ..add([
      'Role',
      'Member (default), Manager, HR or Admin. HR/Admin need an Admin to import.',
    ])
    ..add(['Department', 'One of: ${names('departments').join(', ')}'])
    ..add([
      'Team',
      'Required for new people. One of: ${names('teams').join(', ')}',
    ])
    ..add([
      'Office',
      'One of: ${names('offices').join(', ')} (can be blank if there is only one)',
    ])
    ..add([
      'Shift',
      'One of: ${names('shifts').join(', ')} (can be blank if there is only one)',
    ])
    ..add(['Join date', 'Required for new people. 2026-10-01 or 01/10/2026.'])
    ..add(['Monthly salary', 'Number only, e.g. 45000. Payroll access needed.'])
    ..add([
      'Bank details',
      'Employees add these in My salary and attach proof. HR/Admin approve the request.',
    ])
    ..add([
      'Existing people',
      'Name, designation, department, work email/phone and salary are updated. '
          'Role, team, office and shift are changed on the employee page.',
    ]);
  return [sheet, help];
}
