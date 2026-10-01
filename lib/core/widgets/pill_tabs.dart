import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Segmented switch: a soft track with a white pill that slides to the
/// chosen option. Replaces Material's SegmentedButton (outlined boxes with a
/// check mark) everywhere for a calmer, easier-to-read control. Every tap
/// calls [onChanged], including on the current option (so "Custom" can
/// re-open its picker).
class PillTabs<T> extends StatelessWidget {
  const PillTabs({super.key, required this.options, required this.value, required this.onChanged});

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;

  static const _track = Color(0xFFECEEF3);

  @override
  Widget build(BuildContext context) {
    final n = options.length;
    final index = options.indexWhere((o) => o.$1 == value).clamp(0, n - 1);
    return Container(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: _track, borderRadius: BorderRadius.circular(999)),
      child: Stack(children: [
        AnimatedAlign(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: Alignment(n == 1 ? 0 : -1 + 2 * index / (n - 1), 0),
          child: FractionallySizedBox(
            widthFactor: 1 / n,
            heightFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(999),
                boxShadow: const [
                  BoxShadow(color: Color(0x1A263342), blurRadius: 8, offset: Offset(0, 2)),
                  BoxShadow(color: Color(0x0D263342), blurRadius: 1, offset: Offset(0, 0.5)),
                ],
              ),
            ),
          ),
        ),
        Row(children: [
          for (var i = 0; i < n; i++)
            Expanded(
              child: Semantics(
                button: true,
                selected: i == index,
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => onChanged(options[i].$1),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 200),
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: i == index ? FontWeight.w700 : FontWeight.w500,
                            color: i == index ? AppColors.primary : AppColors.textSecondary,
                          ),
                          child: Text(options[i].$2, maxLines: 1),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ]),
    );
  }
}
