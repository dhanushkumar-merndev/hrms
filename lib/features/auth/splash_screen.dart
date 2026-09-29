import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/auth/session_controller.dart';
import '../../core/widgets/illustration.dart';

/// Startup / reconnect screen while the session is being validated.
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sessionProvider);
    final unreachable = state.phase == SessionPhase.unreachable;
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Illustration('attendance', size: 96),
            const SizedBox(height: AppSpacing.xl),
            if (!unreachable)
              const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3))
            else ...[
              Text('Can\'t reach the server', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              Text(state.message ?? 'Check your connection and try again.',
                  textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                onPressed: () => ref.read(sessionProvider.notifier).refreshContext(),
                child: const Text('Try again'),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
