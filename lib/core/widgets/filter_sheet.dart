import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'app_icon.dart';

/// One group of choices in a [showFilterSheet] (e.g. "Status").
class FilterGroup {
  const FilterGroup({required this.title, required this.options, required this.value, required this.defaultValue});
  final String title;
  final List<(Object?, String)> options;
  final Object? value;
  final Object? defaultValue;
}

/// Top-bar filter icon with a dot when any filter differs from its default.
class FilterButton extends StatelessWidget {
  const FilterButton({super.key, required this.activeCount, required this.onPressed});
  final int activeCount;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: activeCount == 0 ? 'Filter' : 'Filter, $activeCount active',
      onPressed: onPressed,
      icon: Badge(
        isLabelVisible: activeCount > 0,
        label: Text('$activeCount'),
        backgroundColor: AppColors.primary,
        child: const AppIcon(Icons.tune_rounded),
      ),
    );
  }
}

/// Bottom sheet with one row of pill chips per group, plus Reset and Apply.
/// Returns the chosen value for each group (same order), or null if closed.
Future<List<Object?>?> showFilterSheet(BuildContext context, {required List<FilterGroup> groups}) {
  final chosen = [for (final g in groups) g.value];
  return showModalBottomSheet<List<Object?>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
      final t = Theme.of(ctx).textTheme;
      return Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.page, 0, AppSpacing.page, AppSpacing.lg),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('Filter', style: t.titleLarge)),
            TextButton(
              onPressed: () => setState(() {
                for (var i = 0; i < groups.length; i++) {
                  chosen[i] = groups[i].defaultValue;
                }
              }),
              child: const Text('Reset'),
            ),
          ]),
          for (var i = 0; i < groups.length; i++) ...[
            const SizedBox(height: AppSpacing.md),
            Text(groups[i].title.toUpperCase(),
                style: t.labelMedium?.copyWith(
                    color: AppColors.textSecondary, letterSpacing: 0.8, fontWeight: FontWeight.w600)),
            const SizedBox(height: AppSpacing.sm),
            Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
              for (final o in groups[i].options)
                ChoiceChip(
                  label: Text(o.$2),
                  selected: chosen[i] == o.$1,
                  onSelected: (_) => setState(() => chosen[i] = o.$1),
                ),
            ]),
          ],
          const SizedBox(height: AppSpacing.xl),
          FilledButton(onPressed: () => Navigator.pop(ctx, chosen), child: const Text('Show results')),
        ]),
      );
    }),
  );
}
