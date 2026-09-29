import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

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
          placeholderBuilder: (_) => Icon(_fallback[name] ?? Icons.image_outlined, size: size * 0.5),
          errorBuilder: (_, _, _) => Icon(_fallback[name] ?? Icons.image_outlined, size: size * 0.5),
        ),
      ),
    );
  }
}
