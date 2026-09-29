import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'theme.dart';

/// Bottom navigation: Home · Action · Explore (Engage is deferred and hidden,
/// never shown as a dead tab).
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: shell,
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.border))),
        child: NavigationBar(
          selectedIndex: shell.currentIndex,
          onDestinationSelected: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded, color: AppColors.primary),
                label: 'Home'),
            NavigationDestination(
                icon: Icon(Icons.bolt_outlined), selectedIcon: Icon(Icons.bolt_rounded, color: AppColors.primary),
                label: 'Action'),
            NavigationDestination(
                icon: Icon(Icons.grid_view_outlined), selectedIcon: Icon(Icons.grid_view_rounded, color: AppColors.primary),
                label: 'Explore'),
          ],
        ),
      ),
    );
  }
}

/// Shown for routes that are not part of this build yet.
class NotAvailableScreen extends StatelessWidget {
  const NotAvailableScreen({super.key, required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.construction_rounded, size: 44, color: AppColors.textSecondary),
            const SizedBox(height: AppSpacing.md),
            Text('Coming in the next build', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text('This screen ($path) is not available in this version yet.',
                textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
          ]),
        ),
      ),
    );
  }
}
