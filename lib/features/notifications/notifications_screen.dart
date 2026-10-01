import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/paged_list.dart';
import '../../core/widgets/states.dart';
import '../home/home_providers.dart';

/// S19 — the authoritative in-app inbox (push is optional and best effort).
/// Previews carry only lock-screen-safe labels; details open in the app.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  final _list = GlobalKey<PagedListState<Map<String, dynamic>>>();
  final _read = <String>{};

  Future<void> _markAll() async {
    try {
      await ref.read(apiProvider).rpc('mark_notifications_read', {'p_ids': null});
      ref.invalidate(homeSummaryProvider);
      _list.currentState?.reload();
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    }
  }

  Future<void> _open(Map<String, dynamic> n) async {
    final id = n['id'] as String;
    if (n['read_at'] == null && !_read.contains(id)) {
      setState(() => _read.add(id));
      ref.read(apiProvider).rpc('mark_notifications_read', {'p_ids': [id]}).then((_) {
        ref.invalidate(homeSummaryProvider);
      }).ignore();
    }
    final link = n['deep_link'] as String?;
    // Only in-app routes; the target screen re-checks access on the server.
    if (link != null && link.startsWith('/') && !link.startsWith('//') && link != '/notifications') {
      context.push(link);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.read(apiProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications'), actions: [
        TextButton(onPressed: _markAll, child: const Text('Mark all read')),
      ]),
      body: Column(children: [
        const OfflineBanner(),
        Expanded(
          child: PagedList<Map<String, dynamic>>(
            key: _list,
            fetch: (cursor) async {
              final c = cursor as (String, String)?;
              final res = (await api.rpc('list_notifications', {
                'p_before_created_at': c?.$1,
                'p_before_id': c?.$2,
                'p_limit': 30,
              }))
                  .map;
              final rows = ((res['rows'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
              return PageResult(rows,
                  next: rows.length < 30 ? null : (rows.last['created_at'] as String, rows.last['id'] as String));
            },
            empty: const EmptyState(icon: Icons.notifications_none_rounded, title: 'No notifications'),
            itemBuilder: (context, n) {
              final unread = n['read_at'] == null && !_read.contains(n['id']);
              return Material(
                color: unread ? AppColors.attendanceCard : AppColors.surface,
                borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
                  onTap: () => _open(n),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      AppIcon(_icon(n['kind'] as String?), color: AppColors.primary),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Semantics(
                            label: unread ? 'Unread' : null,
                            child: Text(n['title'] as String? ?? '',
                                style: TextStyle(fontSize: 16, fontWeight: unread ? FontWeight.w700 : FontWeight.w500)),
                          ),
                          if (n['body'] != null) Text(n['body'] as String, style: Theme.of(context).textTheme.bodyMedium),
                          const SizedBox(height: 4),
                          Text(OrgTime.dateTime(n['created_at']), style: Theme.of(context).textTheme.bodySmall),
                        ]),
                      ),
                      if (unread)
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: AppIcon(Icons.circle, size: 10, color: AppColors.primary),
                        ),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }

  static IconData _icon(String? kind) {
    final k = kind ?? '';
    if (k.startsWith('payslip')) return Icons.receipt_long_outlined;
    if (k.startsWith('request') || k.startsWith('leave')) return Icons.assignment_outlined;
    if (k.startsWith('device') || k.startsWith('credentials')) return Icons.security_rounded;
    if (k == 'announcement') return Icons.campaign_outlined;
    if (k.startsWith('setup')) return Icons.build_circle_outlined;
    return Icons.notifications_none_rounded;
  }
}
