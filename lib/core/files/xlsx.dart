import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Minimal, dependency-free XLSX (SpreadsheetML) writer for report exports.
///
/// Every text value is written as an inline string, which spreadsheet apps
/// never evaluate as a formula. Values that START like a formula (=, +, -,
/// @, tab, CR) additionally get the quote-prefix style so they stay plain
/// text even after copy/paste or CSV conversion (EXP-008). Dates are typed
/// date cells; numbers are numbers.
class XlsxSheet {
  XlsxSheet(this.name, {this.columnWidths = const []});
  final String name;
  final List<double> columnWidths;
  final List<List<Object?>> rows = [];

  void header(List<String> cells) => rows.add(cells);
  void add(List<Object?> cells) => rows.add(cells);
}

/// A date-only value (no time zone shift): written as a typed date cell.
class XlsxDate {
  const XlsxDate(this.year, this.month, this.day);
  factory XlsxDate.parse(String ymd) {
    final d = DateTime.parse(ymd);
    return XlsxDate(d.year, d.month, d.day);
  }
  final int year;
  final int month;
  final int day;

  /// Days since 1899-12-30 (the 1900 date system).
  int get serial => DateTime.utc(year, month, day).difference(DateTime.utc(1899, 12, 30)).inDays;
}

const _styleHeader = 1;
const _styleDate = 2;
const _styleQuoted = 3;

bool looksLikeFormula(String v) => v.isNotEmpty && '=+-@\t\r'.contains(v[0]);

String _escape(String v) {
  final b = StringBuffer();
  for (final r in v.runes) {
    // Drop characters XML 1.0 cannot carry.
    if (r < 0x20 && r != 0x09 && r != 0x0A && r != 0x0D) continue;
    if (r == 0xFFFE || r == 0xFFFF || (r >= 0xD800 && r <= 0xDFFF)) continue;
    switch (r) {
      case 0x26:
        b.write('&amp;');
      case 0x3C:
        b.write('&lt;');
      case 0x3E:
        b.write('&gt;');
      case 0x22:
        b.write('&quot;');
      default:
        b.writeCharCode(r);
    }
  }
  return b.toString();
}

String columnName(int index) {
  var n = index + 1;
  final chars = <int>[];
  while (n > 0) {
    chars.insert(0, 65 + (n - 1) % 26);
    n = (n - 1) ~/ 26;
  }
  return String.fromCharCodes(chars);
}

String _sheetName(String raw, Set<String> used) {
  var name = raw.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ').trim();
  if (name.isEmpty) name = 'Sheet';
  if (name.length > 31) name = name.substring(0, 31);
  var candidate = name;
  var i = 2;
  while (used.contains(candidate.toLowerCase())) {
    final suffix = ' ($i)';
    candidate = (name.length + suffix.length > 31 ? name.substring(0, 31 - suffix.length) : name) + suffix;
    i++;
  }
  used.add(candidate.toLowerCase());
  return candidate;
}

String _sheetXml(XlsxSheet sheet) {
  final b = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">')
    ..write('<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" '
        'state="frozen"/></sheetView></sheetViews>');
  if (sheet.columnWidths.isNotEmpty) {
    b.write('<cols>');
    for (var i = 0; i < sheet.columnWidths.length; i++) {
      b.write('<col min="${i + 1}" max="${i + 1}" width="${sheet.columnWidths[i]}" customWidth="1"/>');
    }
    b.write('</cols>');
  }
  b.write('<sheetData>');
  for (var r = 0; r < sheet.rows.length; r++) {
    b.write('<row r="${r + 1}">');
    final row = sheet.rows[r];
    for (var c = 0; c < row.length; c++) {
      final v = row[c];
      if (v == null) continue;
      final ref = '${columnName(c)}${r + 1}';
      if (v is num && v.isFinite) {
        b.write('<c r="$ref"><v>$v</v></c>');
      } else if (v is XlsxDate) {
        b.write('<c r="$ref" s="$_styleDate"><v>${v.serial}</v></c>');
      } else {
        final text = v is bool ? (v ? 'Yes' : 'No') : v.toString();
        final style = r == 0 ? _styleHeader : (looksLikeFormula(text) ? _styleQuoted : 0);
        b.write('<c r="$ref" t="inlineStr"${style == 0 ? '' : ' s="$style"'}><is><t xml:space="preserve">'
            '${_escape(text)}</t></is></c>');
      }
    }
    b.write('</row>');
  }
  b.write('</sheetData></worksheet>');
  return b.toString();
}

const _styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy\\-mm\\-dd"/></numFmts>'
    '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
    '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    '<cellXfs count="4">'
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
    '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" quotePrefix="1"/>'
    '</cellXfs>'
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
    '</styleSheet>';

Uint8List buildXlsx(List<XlsxSheet> sheets) {
  final used = <String>{};
  final names = [for (final s in sheets) _sheetName(s.name, used)];
  final archive = Archive();
  void add(String path, String content) => archive.addFile(ArchiveFile.bytes(path, utf8.encode(content)));

  add('[Content_Types].xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/xl/workbook.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      '<Override PartName="/xl/styles.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
      '${[for (var i = 0; i < sheets.length; i++) '<Override PartName="/xl/worksheets/sheet${i + 1}.xml" '
          'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'].join()}'
      '</Types>');
  add('_rels/.rels',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
      'Target="xl/workbook.xml"/></Relationships>');
  add('xl/workbook.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
      '${[for (var i = 0; i < sheets.length; i++) '<sheet name="${_escape(names[i])}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}'
      '</sheets></workbook>');
  add('xl/_rels/workbook.xml.rels',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '${[for (var i = 0; i < sheets.length; i++) '<Relationship Id="rId${i + 1}" '
          'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
          'Target="worksheets/sheet${i + 1}.xml"/>'].join()}'
      '<Relationship Id="rId${sheets.length + 1}" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
      '</Relationships>');
  add('xl/styles.xml', _styles);
  for (var i = 0; i < sheets.length; i++) {
    add('xl/worksheets/sheet${i + 1}.xml', _sheetXml(sheets[i]));
  }
  return ZipEncoder().encodeBytes(archive);
}

const xlsxMime = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
