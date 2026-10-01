import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'app_icon.dart';
import 'illustration.dart';

/// White rounded card used for Home sections and detail blocks.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.child, this.padding, this.color, this.onTap});
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final body = Padding(padding: padding ?? const EdgeInsets.all(AppSpacing.cardPadding), child: child);
    return Card(
      color: color ?? AppColors.surface,
      clipBehavior: Clip.antiAlias,
      child: onTap == null ? body : InkWell(onTap: onTap, child: body),
    );
  }
}

/// Card header row: title + optional trailing arrow action (reference 01).
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.onMore, this.moreLabel});
  final String title;
  final VoidCallback? onMore;
  final String? moreLabel;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
      if (onMore != null)
        IconButton(
          tooltip: moreLabel ?? 'Open $title',
          onPressed: onMore,
          icon: const AppIcon(Icons.north_east_rounded, color: AppColors.text),
        ),
    ]);
  }
}

/// White action row with a soft coloured icon tile (reference 02). With
/// [art] the tile shows that bundled illustration instead of [icon].
class ActionRow extends StatelessWidget {
  const ActionRow({
    super.key,
    required this.icon,
    required this.label,
    required this.tileColor,
    required this.iconColor,
    required this.onTap,
    this.subtitle,
    this.badge,
    this.art,
  });

  final IconData icon;
  final String? art;
  final String label;
  final String? subtitle;
  final Color tileColor;
  final Color iconColor;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(children: [
            Container(
              width: AppSpacing.iconTile,
              height: AppSpacing.iconTile,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: tileColor, borderRadius: BorderRadius.circular(12)),
              child: art == null ? AppIcon(icon, color: iconColor, size: 26) : Illustration(art!, size: 42),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: const TextStyle(fontSize: 18, color: AppColors.text, fontWeight: FontWeight.w500)),
                if (subtitle != null) Text(subtitle!, style: Theme.of(context).textTheme.bodyMedium),
              ]),
            ),
            if (badge != null) CountBadge(badge!),
            const SizedBox(width: AppSpacing.xs),
            const AppIcon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
          ]),
        ),
      ),
    );
  }
}

class CountBadge extends StatelessWidget {
  const CountBadge(this.text, {super.key, this.color = AppColors.error});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }
}

/// Pill-shaped action button inside an expanded Explore card (refs 04–07).
class Pill extends StatelessWidget {
  const Pill({super.key, required this.label, required this.color, required this.onPressed});
  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}

/// Rounded pastel module card with an accordion (refs 03–07). Only one card
/// is expanded at a time; the parent owns that state.
class ModuleCard extends StatelessWidget {
  const ModuleCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.actionColor,
    required this.illustration,
    required this.expanded,
    required this.onToggle,
    required this.actions,
  });

  final String title;
  final String subtitle;
  final Color color;
  final Color actionColor;
  final String illustration;
  final bool expanded;
  final VoidCallback onToggle;
  final List<(String, VoidCallback)> actions;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.cardPadding, AppSpacing.cardPadding, AppSpacing.md, AppSpacing.cardPadding),
          child: AnimatedSize(
            duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Semantics(
                    button: true,
                    expanded: expanded,
                    label: '$title. $subtitle',
                    excludeSemantics: true,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Flexible(
                          child: Text(title,
                              style: Theme.of(context).textTheme.headlineMedium,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 2),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        AnimatedRotation(
                          turns: expanded ? 0.5 : 0,
                          duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 180),
                          child: const AppIcon(Icons.keyboard_arrow_down_rounded, color: AppColors.text, size: 28),
                        ),
                      ]),
                      const SizedBox(height: AppSpacing.sm),
                      Text(subtitle, style: const TextStyle(fontSize: 16, color: AppColors.text, height: 1.35)),
                    ]),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Illustration(illustration, size: 96),
              ]),
              if (expanded && actions.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.lg),
                Wrap(
                  spacing: AppSpacing.md,
                  runSpacing: AppSpacing.md,
                  children: [for (final a in actions) Pill(label: a.$1, color: actionColor, onPressed: a.$2)],
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// Status chip whose meaning is carried by text + icon, not colour alone.
class StatusChip extends StatelessWidget {
  const StatusChip(this.label, {super.key, required this.tone, this.icon});
  final String label;
  final ChipTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (tone) {
      ChipTone.success => (AppColors.successSoft, AppColors.success),
      ChipTone.warning => (AppColors.warningSoft, AppColors.warning),
      ChipTone.error => (AppColors.errorSoft, AppColors.error),
      ChipTone.info => (AppColors.attendanceCard, AppColors.primary),
      ChipTone.neutral => (const Color(0xFFEFF1F4), AppColors.textSecondary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[AppIcon(icon, size: 14, color: fg), const SizedBox(width: 4)],
        Flexible(
          child: Text(label,
              style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
        ),
      ]),
    );
  }
}

enum ChipTone { success, warning, error, info, neutral }

class KeyValueRow extends StatelessWidget {
  const KeyValueRow(this.label, this.value, {super.key});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 130, child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
        Expanded(child: Text(value, style: Theme.of(context).textTheme.bodyLarge)),
      ]),
    );
  }
}

class PageTitle extends StatelessWidget {
  const PageTitle(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(AppSpacing.page + 8, AppSpacing.lg, AppSpacing.page, AppSpacing.lg),
      child: Semantics(header: true, child: Text(title, style: Theme.of(context).textTheme.headlineSmall)),
    );
  }
}
