import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/core/files/xlsx.dart';

String _part(Archive a, String name) => utf8.decode(a.find(name)!.readBytes()!);

void main() {
  test('column names follow spreadsheet lettering', () {
    expect([columnName(0), columnName(25), columnName(26), columnName(701), columnName(702)],
        ['A', 'Z', 'AA', 'ZZ', 'AAA']);
  });

  test('date serials use the 1900 date system', () {
    expect(const XlsxDate(2026, 1, 1).serial, 46023);
    expect(XlsxDate.parse('2024-02-29').serial, 45351);
  });

  test('workbook has the required OOXML parts and typed cells', () {
    final sheet = XlsxSheet('Days')
      ..header(['Name', 'Minutes', 'Date', 'Late'])
      ..add(['Asha', 540, const XlsxDate(2026, 9, 1), true])
      ..add([null, 1.5, null, false]);
    final zip = ZipDecoder().decodeBytes(buildXlsx([sheet]));
    for (final part in ['[Content_Types].xml', '_rels/.rels', 'xl/workbook.xml', 'xl/_rels/workbook.xml.rels',
      'xl/styles.xml', 'xl/worksheets/sheet1.xml']) {
      expect(zip.find(part), isNotNull, reason: part);
    }
    final xml = _part(zip, 'xl/worksheets/sheet1.xml');
    expect(xml, contains('<c r="B2"><v>540</v></c>'));
    expect(xml, contains('<c r="C2" s="2"><v>46266</v></c>'));
    expect(xml, contains('<t xml:space="preserve">Yes</t>'));
    expect(xml, isNot(contains('<f>')));
    expect(_part(zip, 'xl/workbook.xml'), contains('name="Days"'));
  });

  test('EXP-008 formula-like text stays inert text with the quote-prefix style', () {
    final sheet = XlsxSheet('S')..header(['Value']);
    for (final v in ['=HYPERLINK("http://x")', '+1', '-2+3', '@SUM(A1)', 'safe']) {
      sheet.add([v]);
    }
    final xml = _part(ZipDecoder().decodeBytes(buildXlsx([sheet])), 'xl/worksheets/sheet1.xml');
    expect(RegExp(r't="inlineStr" s="3"').allMatches(xml).length, 4);
    expect(xml, contains('&quot;http://x&quot;'));
    expect(xml, isNot(contains('<f>')));
    expect(looksLikeFormula('safe'), isFalse);
  });

  test('XML special and control characters are escaped or dropped', () {
    final sheet = XlsxSheet('S')
      ..header(['V'])
      ..add(['a<b>&"c"\u0001\u0007 d']);
    final xml = _part(ZipDecoder().decodeBytes(buildXlsx([sheet])), 'xl/worksheets/sheet1.xml');
    expect(xml, contains('a&lt;b&gt;&amp;&quot;c&quot; d'));
  });

  test('sheet names are sanitised, truncated and unique', () {
    final zip = ZipDecoder().decodeBytes(buildXlsx([
      XlsxSheet('A/B:C*D?[E]')..header(['x']),
      XlsxSheet('A very long sheet name that exceeds thirty one characters')..header(['x']),
      XlsxSheet('A very long sheet name that exceeds thirty one characters')..header(['x']),
    ]));
    final wb = _part(zip, 'xl/workbook.xml');
    final names = RegExp(r'name="([^"]*)"').allMatches(wb).map((m) => m.group(1)!).toList();
    expect(names[0], 'A B C D  E');
    expect(names[1].length, lessThanOrEqualTo(31));
    expect(names[2], isNot(names[1]));
    expect(names[2].length, lessThanOrEqualTo(31));
  });
}
