import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// One worksheet as plain text cells (row-major; missing cells are '').
class SheetData {
  SheetData(this.name, this.rows);
  final String name;
  final List<List<String>> rows;
}

class SpreadsheetException implements Exception {
  const SpreadsheetException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reads .xlsx (and .csv) files picked by the user. Only cell VALUES are
/// read: formulas are never evaluated (their last cached result is used),
/// macros and external links are ignored. Bounded to keep a hostile file
/// from exhausting memory.
class SpreadsheetReader {
  static const maxBytes = 10 * 1000 * 1000;
  static const maxRows = 5000;
  static const maxCols = 60;
  static const _maxXmlChars = 60 * 1000 * 1000;

  static List<SheetData> read(Uint8List bytes, String filename) {
    if (bytes.length > maxBytes) throw const SpreadsheetException('The file is larger than 10 MB.');
    final lower = filename.toLowerCase();
    if (lower.endsWith('.csv')) return [SheetData('CSV', _csv(utf8.decode(bytes, allowMalformed: true)))];
    if (!lower.endsWith('.xlsx')) {
      throw const SpreadsheetException('Choose an Excel .xlsx file (or .csv). Old .xls files: save as .xlsx first.');
    }
    final Archive zip;
    try {
      zip = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const SpreadsheetException('This file is not a valid Excel workbook.');
    }
    String? text(String path) {
      final f = zip.findFile(path);
      if (f == null) return null;
      final content = f.readBytes();
      if (content == null) return null;
      if (content.length > _maxXmlChars) throw const SpreadsheetException('This workbook is too large to import.');
      return utf8.decode(content, allowMalformed: true);
    }

    final workbookXml = text('xl/workbook.xml');
    if (workbookXml == null) throw const SpreadsheetException('This file is not a valid Excel workbook.');
    final rels = <String, String>{};
    final relsXml = text('xl/_rels/workbook.xml.rels');
    if (relsXml != null) {
      for (final r in XmlDocument.parse(relsXml).findAllElements('Relationship')) {
        final target = r.getAttribute('Target') ?? '';
        rels[r.getAttribute('Id') ?? ''] =
            target.startsWith('/') ? target.substring(1) : 'xl/${target.replaceFirst(RegExp(r'^\./'), '')}';
      }
    }
    final shared = <String>[];
    final sharedXml = text('xl/sharedStrings.xml');
    if (sharedXml != null) {
      for (final si in XmlDocument.parse(sharedXml).findAllElements('si')) {
        shared.add(si.findAllElements('t').map((t) => t.innerText).join());
      }
    }

    final sheets = <SheetData>[];
    var index = 0;
    for (final s in XmlDocument.parse(workbookXml).findAllElements('sheet')) {
      index++;
      final name = s.getAttribute('name') ?? 'Sheet$index';
      final rid = s.attributes.where((a) => a.name.local == 'id').map((a) => a.value).firstOrNull;
      final path = rels[rid] ?? 'xl/worksheets/sheet$index.xml';
      final xml = text(path);
      if (xml == null) continue;
      sheets.add(SheetData(name, _sheetRows(xml, shared)));
    }
    if (sheets.isEmpty) throw const SpreadsheetException('The workbook has no sheets.');
    return sheets;
  }

  static List<List<String>> _sheetRows(String xml, List<String> shared) {
    final rows = <List<String>>[];
    for (final row in XmlDocument.parse(xml).findAllElements('row')) {
      if (rows.length >= maxRows) throw const SpreadsheetException('Too many rows (more than 5,000).');
      final rowIndex = (int.tryParse(row.getAttribute('r') ?? '') ?? rows.length + 1) - 1;
      while (rows.length < rowIndex) {
        rows.add([]);
      }
      final cells = <String>[];
      for (final c in row.findElements('c')) {
        final ref = c.getAttribute('r');
        final col = ref == null ? cells.length : _columnIndex(ref);
        if (col >= maxCols) continue;
        while (cells.length < col) {
          cells.add('');
        }
        final type = c.getAttribute('t');
        final v = c.getElement('v')?.innerText ?? '';
        final value = switch (type) {
          's' => (int.tryParse(v) ?? -1) >= 0 && int.parse(v) < shared.length ? shared[int.parse(v)] : '',
          'inlineStr' => c.findAllElements('t').map((t) => t.innerText).join(),
          'b' => v == '1' ? 'TRUE' : 'FALSE',
          _ => v,
        };
        if (cells.length == col) {
          cells.add(value.trim());
        } else {
          cells[col] = value.trim();
        }
      }
      if (rows.length == rowIndex) rows.add(cells);
    }
    return rows;
  }

  static int _columnIndex(String ref) {
    var n = 0;
    for (final ch in ref.codeUnits) {
      if (ch < 65 || ch > 90) break;
      n = n * 26 + (ch - 64);
    }
    return n - 1;
  }

  static List<List<String>> _csv(String input) {
    final rows = <List<String>>[];
    var row = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (quoted) {
        if (ch == '"') {
          if (i + 1 < input.length && input[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          cell.write(ch);
        }
      } else if (ch == '"') {
        quoted = true;
      } else if (ch == ',') {
        row.add(cell.toString().trim());
        cell.clear();
      } else if (ch == '\n' || ch == '\r') {
        if (ch == '\r' && i + 1 < input.length && input[i + 1] == '\n') i++;
        row.add(cell.toString().trim());
        cell.clear();
        rows.add(row);
        row = <String>[];
        if (rows.length > maxRows) throw const SpreadsheetException('Too many rows (more than 5,000).');
      } else {
        cell.write(ch);
      }
    }
    if (cell.isNotEmpty || row.isNotEmpty) {
      row.add(cell.toString().trim());
      rows.add(row);
    }
    return rows;
  }

  /// Excel serial day (1900 system) or text -> 'YYYY-MM-DD', or null.
  static String? date(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return null;
    final serial = double.tryParse(v);
    if (serial != null && serial > 59 && serial < 2958466) {
      final d = DateTime.utc(1899, 12, 30).add(Duration(days: serial.floor()));
      return _ymd(d);
    }
    final iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(v);
    if (iso != null) return _valid(int.parse(iso[1]!), int.parse(iso[2]!), int.parse(iso[3]!));
    final dmy = RegExp(r'^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$').firstMatch(v);
    if (dmy != null) return _valid(int.parse(dmy[3]!), int.parse(dmy[2]!), int.parse(dmy[1]!)); // Indian d/m/y
    return null;
  }

  static String? _valid(int y, int m, int d) {
    final dt = DateTime.utc(y, m, d);
    return dt.year == y && dt.month == m && dt.day == d ? _ymd(dt) : null;
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
