import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../api/api_exception.dart';
import 'app_icon.dart';

/// Renders an AsyncValue with distinct loading, empty, error, offline and
/// unauthorized states (design.md §4: never conflate "no rows" with failure).
class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    super.key,
    required this.value,
    required this.builder,
    this.onRetry,
    this.isEmpty,
    this.empty,
    this.loading,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;
  final bool Function(T data)? isEmpty;
  final Widget? empty;
  final Widget? loading;

  @override
  Widget build(BuildContext context) {
    return value.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      data: (d) => (isEmpty?.call(d) ?? false) ? (empty ?? const EmptyState()) : builder(d),
      loading: () => loading ?? const SkeletonList(),
      error: (e, _) => ErrorState(error: e, onRetry: onRetry),
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.error, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final api = error is ApiException ? error as ApiException : null;
    if (api?.isAccessDenied ?? false) return const UnauthorizedState();
    final offline = api?.isNetwork ?? false;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(offline ? Icons.wifi_off_rounded : Icons.error_outline_rounded,
                size: 44, color: offline ? AppColors.warning : AppColors.error),
            const SizedBox(height: AppSpacing.md),
            Text(offline ? 'You are offline' : 'Could not load this',
                style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.sm),
            Text(api?.message ?? 'Something went wrong. Please try again.',
                style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
            if (api?.requestId != null) ...[
              const SizedBox(height: AppSpacing.xs),
              SelectableText('Ref: ${api!.requestId!.substring(0, 8)}', style: Theme.of(context).textTheme.bodySmall),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: AppSpacing.lg),
              OutlinedButton.icon(onPressed: onRetry, icon: const AppIcon(Icons.refresh), label: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, this.icon = Icons.inbox_outlined, this.title = 'Nothing here yet', this.message});
  final IconData icon;
  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AppIcon(icon, size: 44, color: AppColors.textSecondary),
          const SizedBox(height: AppSpacing.md),
          Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(message!, style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
          ],
        ]),
      ),
    );
  }
}

class UnauthorizedState extends StatelessWidget {
  const UnauthorizedState({super.key});

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.lock_outline_rounded,
      title: 'No access',
      message: 'You do not have permission to view this. If you think you should, contact your Admin.',
    );
  }
}

class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.items = 4, this.height = 72});
  final int items;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading',
      child: ListView.separated(
        padding: const EdgeInsets.all(AppSpacing.page),
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        itemCount: items,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
        itemBuilder: (_, _) => Container(
          height: height,
          decoration: BoxDecoration(
            color: const Color(0xFFECEFF3),
            borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
          ),
        ),
      ),
    );
  }
}

/// Emits whether the device currently has a network path.
final onlineProvider = StreamProvider<bool>((ref) async* {
  final c = Connectivity();
  yield !(await c.checkConnectivity()).contains(ConnectivityResult.none);
  yield* c.onConnectivityChanged.map((r) => !r.contains(ConnectivityResult.none));
});

class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(onlineProvider).value ?? true;
    if (online) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        color: AppColors.warningSoft,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page, vertical: AppSpacing.sm),
        child: const Row(children: [
          AppIcon(Icons.wifi_off_rounded, size: 18, color: AppColors.warning),
          SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text('Offline — showing saved information. Actions need a connection.',
                style: TextStyle(color: AppColors.warning, fontSize: 14)),
          ),
        ]),
      ),
    );
  }
}
