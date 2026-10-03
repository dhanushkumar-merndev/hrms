import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'app_icon.dart';

/// Small square button with the info illustration. Tapping it opens a sheet
/// with the screen's explanation, so long help text doesn't fill the page.
class InfoButton extends StatelessWidget {
  const InfoButton({super.key, required this.title, required this.message, this.size = 56});
  final String title;
  final String message;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'About $title',
      child: Material(
        color: AppColors.attendanceCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.border),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => showInfoSheet(context, title: title, message: message),
          child: SizedBox.square(
            dimension: size,
            child: const Center(child: AppIcon(Icons.info_outline_rounded, size: 30)),
          ),
        ),
      ),
    );
  }
}

Future<void> showInfoSheet(BuildContext context, {required String title, required String message}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.page, 0, AppSpacing.page, AppSpacing.page),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const AppIcon(Icons.info_outline_rounded, size: 40),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
            ]),
            const SizedBox(height: AppSpacing.lg),
            Text(message, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: AppSpacing.xl),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Got it')),
            ),
          ],
        ),
      ),
    ),
  );
}
