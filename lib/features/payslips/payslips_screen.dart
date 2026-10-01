import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/format.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/states.dart';
import '../files/file_viewer_screen.dart';

/// Pay documents are never cached beyond the screen (architecture §10).
final myPayslipsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return (await ref.read(apiProvider).rpc('list_my_payslips')).map;
});

/// S14 — latest 12 salary months (by salary month, not upload date).
/// S15 is the secure viewer opened from here; amounts are never extracted.
class PayslipsScreen extends ConsumerWidget {
  const PayslipsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(myPayslipsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Payslips')),
      body: Column(children: [
        const OfflineBanner(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => ref.refresh(myPayslipsProvider.future),
            child: AsyncView(
              value: data,
              onRetry: () => ref.invalidate(myPayslipsProvider),
              builder: (d) {
                final slots = ((d['slots'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
                // Only months that have a payslip are listed; the rest are
                // summed up in one line instead of a row each.
                final shown = slots.where((s) => s['status'] == 'available' || s['status'] == 'archived').toList();
                final waiting = slots.length - shown.length;
                return ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
                  if (shown.isEmpty)
                    const EmptyState(
                      icon: Icons.receipt_long_outlined,
                      title: 'No payslips yet',
                      message: 'When HR uploads your payslip it shows up here, and you get a notification.',
                    )
                  else
                    for (final s in shown) ...[_SlotTile(s), const SizedBox(height: AppSpacing.sm)],
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    '${shown.isNotEmpty && waiting > 0 ? '$waiting ${waiting == 1 ? 'month is' : 'months are'} not uploaded yet. ' : ''}'
                    'Payslips are PDFs uploaded by HR; this app does not calculate salary.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ]);
              },
            ),
          ),
        ),
      ]),
    );
  }
}

class _SlotTile extends StatelessWidget {
  const _SlotTile(this.s);
  final Map<String, dynamic> s;

  @override
  Widget build(BuildContext context) {
    final status = s['status'] as String?;
    final month = monthLabel(s['salary_month']);
    final (label, tone, icon) = switch (status) {
      'available' => ('Available', ChipTone.success, Icons.picture_as_pdf_outlined),
      'archived' => ('Archived locally — contact HR', ChipTone.neutral, Icons.inventory_2_outlined),
      _ => ('Not published', ChipTone.neutral, Icons.hourglass_empty_rounded),
    };
    final id = s['file_version_id'] as String?;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
        onTap: id == null ? null : () => openProtectedFile(context, id, 'Payslip · $month'),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: AppColors.salaryCard, borderRadius: BorderRadius.circular(12)),
              child: AppIcon(icon, color: AppColors.salaryAction),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(month, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  StatusChip(label, tone: tone),
                  if (s['replaced'] == true && status == 'available') const StatusChip('Revised', tone: ChipTone.info),
                ]),
                if (s['published_at'] != null && status == 'available')
                  Text('Published ${OrgTime.dateTime(s['published_at'])}', style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
            if (id != null) const AppIcon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
          ]),
        ),
      ),
    );
  }
}
