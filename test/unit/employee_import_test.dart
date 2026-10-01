import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/core/files/xlsx.dart';
import 'package:hrms/core/files/xlsx_reader.dart';
import 'package:hrms/features/employees/employee_import.dart';

final structure = <String, dynamic>{
  'departments': [
    {'id': 'd1', 'name': 'Video Grapher'},
    {'id': 'd2', 'name': 'Social Media'},
  ],
  'teams': [
    {'id': 't1', 'name': 'Video Grapher', 'active': true},
    {'id': 't2', 'name': 'Social Media', 'active': true},
  ],
  'offices': [
    {'id': 'o1', 'name': 'Main Office', 'active': true},
  ],
  'shifts': [
    {'id': 's1', 'name': 'General', 'active': true},
  ],
};

final existing = <String, Map<String, dynamic>>{
  'VG002': {
    'id': 'e2',
    'code': 'VG002',
    'name': 'Chetan',
    'designation': 'Editor',
    'department': {'id': 'd1', 'name': 'Video Grapher'},
    'team': {'id': 't1', 'name': 'Video Grapher'},
    'business_email': null,
    'roles': <String>[],
  },
};

ImportPlan plan(List<List<String>> rows, {bool admin = false, bool payroll = true, String me = 'e9'}) => planImport(
      SheetData('Employees', rows),
      existing: existing,
      structure: structure,
      isAdmin: admin,
      canProvision: true,
      canManagePayroll: payroll,
      myEmployeeId: me,
    );

void main() {
  test('reads a workbook written by the app (round trip, shared/inline strings, numbers, dates)', () {
    final sheet = XlsxSheet('Employees')
      ..header(templateHeaders)
      ..add(['VG004', 'Ravi K', 'Member', 'Editor', 'Video Grapher', 'Video Grapher', '', '', const XlsxDate(2026, 10, 1),
             'ravi@example.com', '', 45000, null, 'HDFC Bank', 'Ravi K', '000012345678', 'HDFC0001234']);
    final sheets = SpreadsheetReader.read(buildXlsx([sheet]), 'staff.xlsx');
    expect(sheets.single.name, 'Employees');
    final row = sheets.single.rows[1];
    expect(row[0], 'VG004');
    expect(SpreadsheetReader.date(row[8]), '2026-10-01', reason: 'typed date cell -> serial -> date');
    expect(row[11], '45000');
  });

  test('CSV with quotes, commas and CRLF', () {
    final rows = SpreadsheetReader.read(
        Uint8List.fromList(utf8.encode('Employee ID,Full name\r\nVG005,"Rao, Asha"\r\nVG006,"He said ""hi"""\r\n')),
        'x.csv').single.rows;
    expect(rows[1], ['VG005', 'Rao, Asha']);
    expect(rows[2], ['VG006', 'He said "hi"']);
  });

  test('rejects non-Excel files with a plain message', () {
    expect(() => SpreadsheetReader.read(Uint8List.fromList([1, 2, 3]), 'a.xlsx'), throwsA(isA<SpreadsheetException>()));
    expect(() => SpreadsheetReader.read(Uint8List(0), 'a.xls'), throwsA(isA<SpreadsheetException>()));
  });

  test('dates: ISO, Indian d/m/y and Excel serials; invalid dates rejected', () {
    expect(SpreadsheetReader.date('2026-10-01'), '2026-10-01');
    expect(SpreadsheetReader.date('01/10/2026'), '2026-10-01');
    expect(SpreadsheetReader.date('46296'), '2026-10-01');
    expect(SpreadsheetReader.date('31/02/2026'), isNull);
    expect(SpreadsheetReader.date('soon'), isNull);
  });

  test('IMP-001 new rows are validated and names resolve case-insensitively', () {
    final p = plan([
      ['Employee ID', 'Full name', 'Role', 'Team', 'Join date', 'Monthly salary', 'Account number', 'Mystery'],
      ['vg004', 'Ravi K', 'member', 'video grapher', '2026-10-01', '₹45,000', '000012345678', 'x'],
      ['VG005', '', 'Manager', 'Nope', '', '', '', ''],
      ['VG006', 'Asha', 'HR', 'Social Media', '01/10/2026', 'abc', '12', ''],
      ['', '', '', '', '', '', '', ''],
      ['VG004', 'Dup', '', 'Social Media', '2026-10-01', '', '', ''],
    ]);
    expect(p.unknownHeaders, ['Mystery']);
    expect(p.rows.length, 4, reason: 'blank lines skipped');
    final ravi = p.rows[0];
    expect(ravi.kind, ImportKind.create);
    expect(ravi.code, 'VG004');
    expect((ravi.teamId, ravi.officeId, ravi.shiftId), ('t1', 'o1', 's1'), reason: 'only office/shift used when blank');
    expect(ravi.salary, {'monthly_salary': 45000, 'account_last4': '5678'});
    final bad = p.rows[1];
    expect(bad.kind, ImportKind.error);
    expect(bad.errors.join('|'), allOf(contains('Full name'), contains('Join date'), contains('Unknown team "Nope"')));
    final hr = p.rows[2];
    expect(hr.errors.join('|'), allOf(contains('Only an Admin'), contains('not a number'), contains('at least 4 digits')));
    expect(p.rows[3].errors.single, contains('more than once'));
  });

  test('IMP-002 existing rows update details + salary only; role/team changes are explained, not applied', () {
    final p = plan([
      ['Employee ID', 'Full name', 'Designation', 'Role', 'Team', 'Work email', 'Monthly salary', 'IFSC'],
      ['VG002', 'Chetan', 'Senior Editor', 'Manager', 'Social Media', 'chetan@example.com', '52000', 'hdfc0001234'],
    ]);
    final r = p.rows.single;
    expect(r.kind, ImportKind.update);
    expect(r.patch, {'designation': 'Senior Editor', 'business_email': 'chetan@example.com'});
    expect(r.salary, {'monthly_salary': 52000, 'ifsc': 'hdfc0001234'});
    expect(r.notes.join('|'), allOf(contains('Role not changed'), contains('Team not changed')));
    expect(p.missingColumns, ['Join date']);
  });

  test('IMP-003 unchanged rows and no-payroll access', () {
    final p = plan([
      ['Employee ID', 'Full name', 'Designation', 'Monthly salary'],
      ['VG002', 'Chetan', 'Editor', '50000'],
    ], payroll: false);
    expect(p.rows.single.kind, ImportKind.unchanged);
    expect(p.rows.single.notes.single, contains('payroll access'));
  });

  test('IMP-004 payroll staff cannot change their own salary by import', () {
    final p = plan([
      ['Employee ID', 'Monthly salary'],
      ['VG002', '99999'],
    ], me: 'e2');
    expect(p.rows.single.kind, ImportKind.unchanged);
    expect(p.rows.single.notes.single, contains('Your own salary'));
  });

  test('IMP-005 header found below a title row; no Employee ID column -> nothing planned', () {
    final p = plan([
      ['Staff list October'],
      ['Emp ID', 'Name', 'DOJ', 'Team'],
      ['SM003', 'Kiran', '2026-10-05', 'Social Media'],
    ]);
    expect(p.rows.single.kind, ImportKind.create);
    expect(plan([['Name'], ['x']]).missingColumns, ['Employee ID']);
  });

  test('template lists this organisation\'s teams', () {
    final sheets = importTemplate(structure);
    expect(sheets.map((s) => s.name), ['Employees', 'Instructions']);
    expect(sheets.first.rows.first, templateHeaders);
    expect(sheets.last.rows.expand((r) => r).join(' '), contains('Video Grapher, Social Media'));
  });
}
