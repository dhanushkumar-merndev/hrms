import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';

/// Destination item for [JellyNavigationBar].
class JellyNavDestination {
  const JellyNavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.tooltip,
  });

  final Widget icon;
  final Widget selectedIcon;
  final String label;
  final String? tooltip;
}

/// A high-performance, fluid bottom navigation bar with a jelly-spring
/// active background pill that stretches, squashes, and bounces smoothly
/// between tabs.
class JellyNavigationBar extends StatefulWidget {
  const JellyNavigationBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.backgroundColor,
    this.indicatorColor,
    this.selectedColor,
    this.unselectedColor,
    this.height = 68.0,
    this.showTopBorder = true,
  }) : assert(destinations.length >= 2, 'At least 2 destinations are required');

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<JellyNavDestination> destinations;
  final Color? backgroundColor;
  final Color? indicatorColor;
  final Color? selectedColor;
  final Color? unselectedColor;
  final double height;
  final bool showTopBorder;

  @override
  State<JellyNavigationBar> createState() => _JellyNavigationBarState();
}

class _JellyNavigationBarState extends State<JellyNavigationBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  // Fractional index tracking for resolution-independent jelly motion
  double _startFracIndex = 0.0;
  double _targetFracIndex = 0.0;
  bool _isInPlaceTap = false;

  @override
  void initState() {
    super.initState();
    _startFracIndex = widget.selectedIndex.toDouble();
    _targetFracIndex = widget.selectedIndex.toDouble();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
  }

  @override
  void didUpdateWidget(JellyNavigationBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _startMove(widget.selectedIndex);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _startMove(int newIndex) {
    final currentPhysicalFrac = _evalCurrentFracIndex();
    setState(() {
      _isInPlaceTap = false;
      _startFracIndex = currentPhysicalFrac;
      _targetFracIndex = newIndex.toDouble();
    });
    _controller.forward(from: 0.0);
  }

  void _triggerInPlaceBounce() {
    setState(() {
      _isInPlaceTap = true;
      _startFracIndex = widget.selectedIndex.toDouble();
      _targetFracIndex = widget.selectedIndex.toDouble();
    });
    _controller.forward(from: 0.0);
  }

  double _evalCurrentFracIndex() {
    if (!_controller.isAnimating) {
      return _targetFracIndex;
    }
    final t = _controller.value;
    final delta = _targetFracIndex - _startFracIndex;
    if (delta.abs() < 0.001) return _targetFracIndex;

    double posRatio;
    if (t < 0.70) {
      final p = t / 0.70;
      posRatio = p * p * (3.0 - 2.0 * p);
    } else {
      final p = (t - 0.70) / 0.30;
      final overshoot = math.sin(p * math.pi) * math.exp(-p * 3.5) * 0.05;
      posRatio = 1.0 + overshoot;
    }
    return _startFracIndex + delta * posRatio;
  }

  void _handleTap(int index) {
    HapticFeedback.selectionClick();
    if (index == widget.selectedIndex) {
      _triggerInPlaceBounce();
    } else {
      _startMove(index);
    }
    widget.onDestinationSelected(index);
  }

  @override
  Widget build(BuildContext context) {
    final navTheme = Theme.of(context).navigationBarTheme;
    final bgColor =
        widget.backgroundColor ?? navTheme.backgroundColor ?? AppColors.surface;
    final pillColor =
        widget.indicatorColor ??
        navTheme.indicatorColor ??
        AppColors.attendanceCard;
    final activeColor = widget.selectedColor ?? AppColors.primary;
    final inactiveColor = widget.unselectedColor ?? AppColors.textSecondary;

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        border: widget.showTopBorder
            ? const Border(top: BorderSide(color: AppColors.border, width: 1.0))
            : null,
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: widget.height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final totalWidth = constraints.maxWidth;
              final tabCount = widget.destinations.length;
              final tabWidth = totalWidth / tabCount;

              return Stack(
                clipBehavior: Clip.none,
                children: [
                  // 1. Jelly Active Background Pill (GPU-accelerated CustomPainter)
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: AnimatedBuilder(
                        animation: _controller,
                        builder: (context, _) {
                          return CustomPaint(
                            painter: _JellyPillPainter(
                              progress: _controller.value,
                              startFracIndex: _startFracIndex,
                              targetFracIndex: _targetFracIndex,
                              isInPlaceTap: _isInPlaceTap,
                              tabWidth: tabWidth,
                              pillColor: pillColor,
                              barHeight: widget.height,
                            ),
                          );
                        },
                      ),
                    ),
                  ),

                  // 2. Tab items (Icons & Labels)
                  Row(
                    children: [
                      for (int i = 0; i < tabCount; i++)
                        Expanded(
                          child: _JellyNavItem(
                            index: i,
                            isSelected: i == widget.selectedIndex,
                            destination: widget.destinations[i],
                            activeColor: activeColor,
                            inactiveColor: inactiveColor,
                            animation: _controller,
                            isAnimatingToThis:
                                _controller.isAnimating &&
                                _targetFracIndex.round() == i,
                            onTap: () => _handleTap(i),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Custom painter for the organic squash-and-stretch jelly pill.
class _JellyPillPainter extends CustomPainter {
  _JellyPillPainter({
    required this.progress,
    required this.startFracIndex,
    required this.targetFracIndex,
    required this.isInPlaceTap,
    required this.tabWidth,
    required this.pillColor,
    required this.barHeight,
  }) : _paint = Paint()
         ..color = pillColor
         ..isAntiAlias = true
         ..style = PaintingStyle.fill;

  final double progress;
  final double startFracIndex;
  final double targetFracIndex;
  final bool isInPlaceTap;
  final double tabWidth;
  final Color pillColor;
  final double barHeight;
  final Paint _paint;

  static const double baseWidth = 64.0;
  static const double baseHeight = 32.0;
  // Pill sits in top icon zone: height 32, centered at y = 24.
  static const double centerY = 24.0;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress;
    final delta = targetFracIndex - startFracIndex;

    double centerX;
    double width;
    double height;

    if (isInPlaceTap || delta.abs() < 0.001) {
      // In-place gentle jelly squash bounce
      centerX = (targetFracIndex + 0.5) * tabWidth;
      final wobble = math.sin(t * math.pi * 2) * math.exp(-t * 4.0);
      width = baseWidth * (1.0 + wobble * 0.24);
      height = baseHeight * (1.0 - wobble * 0.24);
    } else if (t >= 1.0) {
      // Completed rest state
      centerX = (targetFracIndex + 0.5) * tabWidth;
      width = baseWidth;
      height = baseHeight;
    } else {
      // Travel phase: Position interpolation
      double posRatio;
      if (t < 0.70) {
        final p = t / 0.70;
        posRatio = p * p * (3.0 - 2.0 * p); // smoothstep
      } else {
        final p = (t - 0.70) / 0.30;
        final overshoot = math.sin(p * math.pi) * math.exp(-p * 3.5) * 0.05;
        posRatio = 1.0 + overshoot;
      }

      final fracIndex = startFracIndex + delta * posRatio;
      centerX = (fracIndex + 0.5) * tabWidth;

      // Jelly Squash & Stretch deformation
      final distanceAbs = delta.abs().clamp(0.6, 2.5);
      final maxStretch = 0.48 * math.sqrt(distanceAbs);

      double widthFactor;
      if (t < 0.65) {
        // High-velocity stretching along direction of motion
        final p = t / 0.65;
        widthFactor = 1.0 + math.sin(p * math.pi) * maxStretch;
      } else {
        // Impact squash and elastic settling
        final p = (t - 0.65) / 0.35;
        final impact =
            -math.sin(p * math.pi * 2) *
            math.exp(-p * 3.2) *
            0.22 *
            math.sqrt(distanceAbs);
        widthFactor = 1.0 + impact;
      }

      // Volume conservation: height scales inversely to preserve jelly mass
      final heightFactor = 1.0 / math.sqrt(widthFactor);

      width = baseWidth * widthFactor;
      height = baseHeight * heightFactor;
    }

    // Draw the rounded stadium jelly pill
    final rect = Rect.fromCenter(
      center: Offset(centerX, centerY),
      width: width,
      height: height,
    );
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(height / 2));
    canvas.drawRRect(rrect, _paint);
  }

  @override
  bool shouldRepaint(_JellyPillPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.startFracIndex != startFracIndex ||
        oldDelegate.targetFracIndex != targetFracIndex ||
        oldDelegate.isInPlaceTap != isInPlaceTap ||
        oldDelegate.tabWidth != tabWidth ||
        oldDelegate.pillColor != pillColor;
  }
}

/// Interactive navigation item with icon bounce and smooth typography transitions.
class _JellyNavItem extends StatelessWidget {
  const _JellyNavItem({
    required this.index,
    required this.isSelected,
    required this.destination,
    required this.activeColor,
    required this.inactiveColor,
    required this.animation,
    required this.isAnimatingToThis,
    required this.onTap,
  });

  final int index;
  final bool isSelected;
  final JellyNavDestination destination;
  final Color activeColor;
  final Color inactiveColor;
  final Animation<double> animation;
  final bool isAnimatingToThis;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: isSelected,
      label: destination.label,
      tooltip: destination.tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Icon container with pill-landing bounce reaction
            SizedBox(
              height: 32,
              width: 64,
              child: Center(
                child: AnimatedBuilder(
                  animation: animation,
                  builder: (context, child) {
                    double scale = 1.0;
                    if (isSelected && isAnimatingToThis) {
                      final t = animation.value;
                      if (t > 0.60) {
                        final p = (t - 0.60) / 0.40;
                        // Micro-pop when the jelly pill lands
                        scale = 1.0 + math.sin(p * math.pi) * 0.16;
                      }
                    }
                    return Transform.scale(
                      scale: scale,
                      child: IconTheme(
                        data: IconThemeData(
                          color: isSelected ? activeColor : inactiveColor,
                          size: 24,
                        ),
                        child: isSelected
                            ? destination.selectedIcon
                            : destination.icon,
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 4),
            // Label text
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected ? activeColor : inactiveColor,
                height: 1.2,
              ),
              child: Text(
                destination.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
