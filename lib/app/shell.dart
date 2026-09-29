import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      bottomNavigationBar: PillBounceNavBar(
        currentIndex: shell.currentIndex,
        onTap: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
        items: const [
          PillNavItem(
            icon: Icons.home_outlined,
            selectedIcon: Icons.home_rounded,
            label: 'Home',
          ),
          PillNavItem(
            icon: Icons.bolt_outlined,
            selectedIcon: Icons.bolt_rounded,
            label: 'Action',
          ),
          PillNavItem(
            icon: Icons.grid_view_outlined,
            selectedIcon: Icons.grid_view_rounded,
            label: 'Explore',
          ),
        ],
      ),
    );
  }
}

class PillNavItem {
  const PillNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class PillBounceNavBar extends StatelessWidget {
  const PillBounceNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<PillNavItem> items;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(32),
          border: Border.all(
            color: AppColors.border.withValues(alpha: 0.8),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF1E293B).withValues(alpha: 0.08),
              blurRadius: 20,
              offset: const Offset(0, 6),
              spreadRadius: -2,
            ),
            BoxShadow(
              color: AppColors.primary.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: List.generate(items.length, (index) {
            final item = items[index];
            final isSelected = index == currentIndex;
            return PillBounceNavItem(
              item: item,
              isSelected: isSelected,
              onTap: () => onTap(index),
            );
          }),
        ),
      ),
    );
  }
}

class PillBounceNavItem extends StatefulWidget {
  const PillBounceNavItem({
    super.key,
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  final PillNavItem item;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  State<PillBounceNavItem> createState() => _PillBounceNavItemState();
}

class _PillBounceNavItemState extends State<PillBounceNavItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
      reverseDuration: const Duration(milliseconds: 320),
    );

    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 0.86)
            .chain(CurveTween(curve: Curves.easeInQuad)),
        weight: 35,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.86, end: 1.0)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 65,
      ),
    ]).animate(_controller);
  }

  @override
  void didUpdateWidget(covariant PillBounceNavItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isSelected && widget.isSelected) {
      _controller.forward(from: 0.0);
    }
  }

  void _onTapDown(TapDownDetails _) {
    _controller.animateTo(0.35, duration: const Duration(milliseconds: 80), curve: Curves.easeOut);
  }

  void _onTapUp(TapUpDetails _) {
    HapticFeedback.lightImpact();
    widget.onTap();
    _controller.forward(from: 0.35);
  }

  void _onTapCancel() {
    _controller.reverse();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.isSelected;
    final item = widget.item;

    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final scale = _scaleAnimation.value;
          final squashX = 1.0 + (1.0 - scale) * 0.45;
          final squashY = scale;

          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(squashX, squashY, 1.0),
            child: child,
          );
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.symmetric(
            horizontal: isSelected ? 16 : 14,
            vertical: 8,
          ),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.primary.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (child, animation) =>
                    ScaleTransition(scale: animation, child: child),
                child: Icon(
                  isSelected ? item.selectedIcon : item.icon,
                  key: ValueKey('${item.label}_$isSelected'),
                  color: isSelected ? AppColors.primary : AppColors.textSecondary,
                  size: 22,
                ),
              ),
              AnimatedCrossFade(
                duration: const Duration(milliseconds: 200),
                crossFadeState: isSelected
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                firstChild: const SizedBox.shrink(),
                secondChild: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    item.label,
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
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
