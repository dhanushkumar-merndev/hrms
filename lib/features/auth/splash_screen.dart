import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/auth/session_controller.dart';

/// Startup / reconnect screen while the session is being validated.
/// Displays the clean brand logo matching the native launch screen.
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sessionProvider);
    final unreachable = state.phase == SessionPhase.unreachable;
    final t = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: AppColors.surface,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/brand/logo.png',
                width: 72,
                height: 72,
                semanticLabel: 'Internal HRMS logo',
              ),
              if (unreachable) ...[
                const SizedBox(height: AppSpacing.xl),
                Text('Can\'t reach the server', style: t.titleMedium),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  state.message ?? 'Check your connection and try again.',
                  textAlign: TextAlign.center,
                  style: t.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton(
                  onPressed: () => ref.read(sessionProvider.notifier).refreshContext(),
                  child: const Text('Try again'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
