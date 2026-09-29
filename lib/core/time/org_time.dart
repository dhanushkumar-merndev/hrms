import 'package:intl/intl.dart';
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Converts server UTC instants to the organisation/office time zone. The
/// device clock and zone are never authoritative for business dates.
class OrgTime {
  OrgTime._();

  static bool _initialised = false;
  static tz.Location _location = tz.UTC;

  static void init(String zone) {
    if (!_initialised) {
      tzdata.initializeTimeZones();
      _initialised = true;
    }
    try {
      _location = tz.getLocation(zone);
    } catch (_) {
      _location = tz.getLocation('Asia/Kolkata');
    }
  }

  static tz.TZDateTime local(DateTime utc) => tz.TZDateTime.from(utc, _location);

  /// UTC instant for a local calendar day + clock time in the org zone.
  static DateTime atLocal(DateTime day, int hour, int minute, {int addDays = 0}) =>
      tz.TZDateTime(_location, day.year, day.month, day.day + addDays, hour, minute).toUtc();

  static DateTime? parse(Object? iso) {
    if (iso is! String || iso.isEmpty) return null;
    return DateTime.tryParse(iso)?.toUtc();
  }

  static String time(Object? iso) {
    final d = parse(iso);
    return d == null ? '—' : DateFormat('h:mm a').format(local(d));
  }

  static String dateTime(Object? iso) {
    final d = parse(iso);
    return d == null ? '—' : DateFormat('d MMM yyyy, h:mm a').format(local(d));
  }

  /// Formats a server `date` (YYYY-MM-DD, already an org-local date).
  static String date(Object? ymd, {String pattern = 'EEE, d MMM yyyy'}) {
    if (ymd is! String || ymd.isEmpty) return '—';
    final d = DateTime.tryParse(ymd);
    return d == null ? ymd : DateFormat(pattern).format(d);
  }

  static String ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  /// Today's date in the organisation time zone.
  static DateTime today() {
    final now = local(DateTime.now().toUtc());
    return DateTime(now.year, now.month, now.day);
  }

  /// "H h M min" without rounding away deficits (seconds truncated).
  static String hm(num? seconds, {bool compact = false}) {
    final s = (seconds ?? 0).toInt();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    if (compact) return '$h:${m.toString().padLeft(2, '0')}';
    if (h == 0) return '$m min';
    return m == 0 ? '$h h' : '$h h $m min';
  }
}
