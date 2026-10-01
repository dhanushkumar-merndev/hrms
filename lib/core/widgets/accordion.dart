import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'app_icon.dart';

/// Collapsible card: tinted icon, title, one-line summary while closed,
/// rotating chevron. The body is built only while open (so sections that
/// load or audit on open do so only when someone actually looks). [action]
/// (e.g. Edit/Change) shows in the header while open.
class AccordionSection extends StatelessWidget {
  const AccordionSection({
    super.key,
    required this.title,
    required this.icon,
    required this.expanded,
    required this.onToggle,
    required this.child,
    this.summary,
    this.action,
    this.tint = AppColors.attendanceCard,
    this.iconColor = AppColors.primary,
  });

  final String title;
  final IconData icon;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;
  final String? summary;
  final Widget? action;
  final Color tint;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      color: AppColors.surface,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: expanded,
            child: InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.sm, AppSpacing.md),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(12)),
                      child: AppIcon(icon, size: 22, color: iconColor),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: t.titleSmall),
                          if (summary != null)
                            AnimatedOpacity(
                              duration: const Duration(milliseconds: 200),
                              opacity: expanded ? 0.6 : 1,
                              child: Text(
                                summary!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.bodySmall?.copyWith(color: AppColors.textSecondary),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (expanded && action != null) action!,
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: AppIcon(Icons.keyboard_arrow_down_rounded, color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: expanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Divider(height: 1, indent: AppSpacing.lg, endIndent: AppSpacing.lg),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
                        child: child,
                      ),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
