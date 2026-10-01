import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/widgets/jelly_nav_bar.dart';
import 'theme.dart';

/// Bottom navigation: Home · Action · Explore (Engage is deferred and hidden,
/// never shown as a dead tab).
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    // Back on Action/Explore goes to Home first; only Back on Home leaves.
    return PopScope(
      canPop: shell.currentIndex == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) shell.goBranch(0);
      },
      child: _scaffold(),
    );
  }

  Widget _scaffold() {
    return Scaffold(
      body: shell,
      bottomNavigationBar: JellyNavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
        destinations: const [
          JellyNavDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded, color: AppColors.primary),
            label: 'Home',
          ),
          JellyNavDestination(
            icon: Icon(Icons.bolt_outlined),
            selectedIcon: Icon(Icons.bolt_rounded, color: AppColors.primary),
            label: 'Action',
          ),
          JellyNavDestination(
            icon: Icon(Icons.grid_view_outlined),
            selectedIcon: Icon(Icons.grid_view_rounded, color: AppColors.primary),
            label: 'Explore',
          ),
        ],
      ),
    );
  }
}

/// Hosts the tab Navigators in a PageView so people can swipe left/right
/// between Home, Action and Explore. Tapping a tab animates to it; each tab
/// keeps its state (scroll position, open sub-screens) while off screen.
class SwipeTabs extends StatefulWidget {
  const SwipeTabs({super.key, required this.shell, required this.children});
  final StatefulNavigationShell shell;
  final List<Widget> children;

  @override
  State<SwipeTabs> createState() => _SwipeTabsState();
}

class _SwipeTabsState extends State<SwipeTabs> {
  late final PageController _pages = PageController(initialPage: widget.shell.currentIndex);
  int? _animatingTo;

  @override
  void didUpdateWidget(SwipeTabs old) {
    super.didUpdateWidget(old);
    final target = widget.shell.currentIndex;
    if (!_pages.hasClients || _pages.page?.round() == target || _animatingTo == target) return;
    _animatingTo = target;
    _pages
        .animateToPage(target, duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic)
        .whenComplete(() => _animatingTo = null);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageView(
      controller: _pages,
      onPageChanged: (i) {
        // Ignore pages passed over while animating to a tapped tab.
        if (_animatingTo != null || i == widget.shell.currentIndex) return;
        widget.shell.goBranch(i);
      },
      children: [for (final child in widget.children) _KeepAlive(child: child)],
    );
  }
}

class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});
  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
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
