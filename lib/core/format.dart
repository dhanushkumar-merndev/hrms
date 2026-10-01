import 'package:intl/intl.dart';

/// Decimal units (the 5 MB cap is exactly 5,000,000 bytes).
String formatBytes(num? bytes) {
  final b = (bytes ?? 0).toDouble();
  if (b < 1000) return '${b.toInt()} B';
  if (b < 1000000) return '${(b / 1000).toStringAsFixed(b < 10000 ? 1 : 0)} KB';
  if (b < 1000000000) return '${(b / 1000000).toStringAsFixed(1)} MB';
  return '${(b / 1000000000).toStringAsFixed(2)} GB';
}

String roleLabel(String role) => switch (role) {
      'admin' => 'Admin',
      'hr' => 'HR',
      'manager' => 'Manager',
      _ => role,
    };

String permissionLabel(String p) => switch (p) {
      'payroll.manage' => 'Payroll uploads',
      'documents.medical' => 'Medical attachments',
      'hr.employees.provision' => 'Create employees',
      'hr.master_data' => 'Edit employee records',
      'policy.draft' => 'Draft policies & holidays',
      'audit.scoped' => 'Audit history',
      'announcements.publish' => 'Announcements',
      _ => p,
    };

/// Weekday mask used by shifts: bit 0 = Monday ... bit 6 = Sunday.
const weekdayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String weekdaysLabel(int mask) {
  if (mask == 31) return 'Mon–Fri';
  if (mask == 63) return 'Mon–Sat';
  if (mask == 127) return 'Every day';
  return [for (var i = 0; i < 7; i++) if (mask & (1 << i) != 0) weekdayShort[i]].join(', ');
}

String monthLabel(Object? ymd) {
  if (ymd is! String || ymd.isEmpty) return '—';
  final d = DateTime.tryParse(ymd);
  return d == null ? ymd : DateFormat('MMM yyyy').format(d);
}

/// "10:00:00" -> "10:00 AM" (server local time-of-day values).
String clockLabel(Object? hms) {
  if (hms is! String || hms.length < 5) return '—';
  final h = int.tryParse(hms.substring(0, 2)) ?? 0;
  final m = int.tryParse(hms.substring(3, 5)) ?? 0;
  return DateFormat('h:mm a').format(DateTime(2000, 1, 1, h, m));
}

String initialsOf(String? name) {
  final parts = (name ?? '').trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  final first = parts.first.runes.isEmpty ? '' : String.fromCharCode(parts.first.runes.first);
  final last = parts.length > 1 && parts.last.runes.isNotEmpty ? String.fromCharCode(parts.last.runes.first) : '';
  return (first + last).toUpperCase();
}
