import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'app_icon.dart';

/// Decorative module art (original SVGs bundled in assets/illustrations).
/// Excluded from screen readers; falls back to an icon if missing.
class Illustration extends StatelessWidget {
  const Illustration(this.name, {super.key, this.size = 96});
  final String name;
  final double size;

  static const _fallback = {
    'attendance': Icons.event_available_rounded,
    'leave': Icons.flight_takeoff_rounded,
    'salary': Icons.account_balance_wallet_outlined,
    'people': Icons.people_alt_outlined,
    'todo': Icons.fact_check_outlined,
    'documents': Icons.description_outlined,
    'workspace': Icons.insights_rounded,
    'admin': Icons.admin_panel_settings_outlined,
    'holiday_calendar': Icons.event_outlined,
    'tile_apply_leave': Icons.flight_takeoff_rounded,
    'tile_fix_punch': Icons.edit_calendar_outlined,
    'tile_my_attendance': Icons.event_available_outlined,
    'tile_my_requests': Icons.assignment_outlined,
    'tile_review_requests': Icons.fact_check_outlined,
    'tile_team_hours': Icons.groups_outlined,
    'tile_leave_balance': Icons.view_week_outlined,
    'tile_my_salary': Icons.credit_card_rounded,
    'tile_payslips': Icons.receipt_long_outlined,
    'status_on_time': Icons.check_circle_outline_rounded,
    'status_late': Icons.schedule_rounded,
    'status_not_in': Icons.meeting_room_outlined,
    'status_away': Icons.work_outline_rounded,
  };

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: SvgPicture.asset(
          'assets/illustrations/$name.svg',
          fit: BoxFit.contain,
          placeholderBuilder: (_) => AppIcon(_fallback[name] ?? Icons.image_outlined, size: size * 0.5),
          errorBuilder: (_, _, _) => AppIcon(_fallback[name] ?? Icons.image_outlined, size: size * 0.5),
        ),
      ),
    );
  }
}
