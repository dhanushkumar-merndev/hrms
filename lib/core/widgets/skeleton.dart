import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Preset color tones for realistic shimmer skeletons.
/// Supports classic Instagram/Facebook light grey as well as obsidian dark/black.
enum SkeletonTone {
  grey(
    base: Color(0xFFE2E8F0),
    highlight: Color(0xFFFFFFFF),
    cardBackground: Colors.white,
    borderColor: Color(0xFFE3E7ED),
    scaffoldBackground: Color(0xFFF6F7F9),
  ),
  dark(
    base: Color(0xFF242A35),
    highlight: Color(0xFF3F4858),
    cardBackground: Color(0xFF181D26),
    borderColor: Color(0xFF2C3442),
    scaffoldBackground: Color(0xFF0F1319),
  );

  const SkeletonTone({
    required this.base,
    required this.highlight,
    required this.cardBackground,
    required this.borderColor,
    required this.scaffoldBackground,
  });

  final Color base;
  final Color highlight;
  final Color cardBackground;
  final Color borderColor;
  final Color scaffoldBackground;
}

/// Root shimmer provider. Manages a synchronized, GPU-accelerated animation
/// controller that powers all child skeleton bones across the screen in unison.
class SkeletonShimmer extends StatefulWidget {
  const SkeletonShimmer({
    super.key,
    required this.child,
    this.tone = SkeletonTone.grey,
    this.duration = const Duration(milliseconds: 1400),
  });

  final Widget child;
  final SkeletonTone tone;
  final Duration duration;

  /// Returns the current tone from the nearest ancestor [SkeletonShimmer].
  static SkeletonTone toneOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<_ShimmerScope>()?.tone ??
        SkeletonTone.grey;
  }

  /// Returns the synchronized animation controller from the nearest ancestor [SkeletonShimmer].
  static Animation<double>? animationOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<_ShimmerScope>()?.animation;
  }

  @override
  State<SkeletonShimmer> createState() => _SkeletonShimmerState();
}

class _SkeletonShimmerState extends State<SkeletonShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _ShimmerScope(
      animation: _controller,
      tone: widget.tone,
      child: widget.child,
    );
  }
}

class _ShimmerScope extends InheritedWidget {
  const _ShimmerScope({
    required this.animation,
    required this.tone,
    required super.child,
  });

  final Animation<double> animation;
  final SkeletonTone tone;

  @override
  bool updateShouldNotify(_ShimmerScope oldWidget) {
    return oldWidget.animation != animation || oldWidget.tone != tone;
  }
}

/// Applies the animated sweep gradient to its child bones.
/// Uses the parent [SkeletonShimmer] animation if available, or drives its own.
class ShimmerLayer extends StatefulWidget {
  const ShimmerLayer({
    super.key,
    required this.child,
    this.tone,
  });

  final Widget child;
  final SkeletonTone? tone;

  @override
  State<ShimmerLayer> createState() => _ShimmerLayerState();
}

class _ShimmerLayerState extends State<ShimmerLayer>
    with SingleTickerProviderStateMixin {
  AnimationController? _localController;

  @override
  void dispose() {
    _localController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final parentAnim = SkeletonShimmer.animationOf(context);
    final tone = widget.tone ?? SkeletonShimmer.toneOf(context);

    Animation<double> anim;
    if (parentAnim != null) {
      anim = parentAnim;
    } else {
      _localController ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1400),
      )..repeat();
      anim = _localController!;
    }

    return AnimatedBuilder(
      animation: anim,
      child: widget.child,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            final t = anim.value;
            // Sweep smoothly from -1.5 to +2.5 across bounds
            final offset = -1.5 + (t * 4.0);
            return LinearGradient(
              begin: Alignment(offset - 1.2, -0.3),
              end: Alignment(offset + 1.2, 0.3),
              colors: [
                tone.base,
                tone.base,
                tone.highlight,
                tone.base,
                tone.base,
              ],
              stops: const [0.0, 0.35, 0.5, 0.65, 1.0],
            ).createShader(bounds);
          },
          child: child,
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// SKELETON PRIMITIVES
// -----------------------------------------------------------------------------

/// Basic geometric placeholder bone (rounded rectangle or circle).
class SkeletonBone extends StatelessWidget {
  const SkeletonBone({
    super.key,
    this.width,
    this.height,
    this.borderRadius,
    this.shape = BoxShape.rectangle,
    this.margin,
  });

  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final BoxShape shape;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final tone = SkeletonShimmer.toneOf(context);
    return Container(
      width: width,
      height: height,
      margin: margin,
      decoration: BoxDecoration(
        color: tone.base,
        shape: shape,
        borderRadius: shape == BoxShape.circle
            ? null
            : (borderRadius ?? BorderRadius.circular(6)),
      ),
    );
  }
}

/// Simulated text line with rounded pill ends.
class SkeletonLine extends StatelessWidget {
  const SkeletonLine({
    super.key,
    this.width,
    this.height = 14,
    this.borderRadius = 6,
    this.margin,
  });

  final double? width;
  final double height;
  final double borderRadius;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final tone = SkeletonShimmer.toneOf(context);
    return Container(
      width: width,
      height: height,
      margin: margin,
      decoration: BoxDecoration(
        color: tone.base,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
}

/// Round or squircle avatar placeholder.
class SkeletonAvatar extends StatelessWidget {
  const SkeletonAvatar({
    super.key,
    this.size = 44,
    this.isCircle = true,
    this.radius,
  });

  final double size;
  final bool isCircle;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final tone = SkeletonShimmer.toneOf(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tone.base,
        shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: isCircle
            ? null
            : BorderRadius.circular(radius ?? AppSpacing.rowRadius),
      ),
    );
  }
}

/// Pill-shaped badge/chip placeholder.
class SkeletonChip extends StatelessWidget {
  const SkeletonChip({
    super.key,
    this.width = 68,
    this.height = 24,
  });

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final tone = SkeletonShimmer.toneOf(context);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: tone.base,
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}

/// Container card matching the app's [SectionCard] and theme card radius.
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.cardPadding),
    this.margin,
  });

  final Widget child;
  final EdgeInsets padding;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final tone = SkeletonShimmer.toneOf(context);
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: tone.cardBackground,
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        border: Border.all(color: tone.borderColor),
      ),
      child: ShimmerLayer(child: child),
    );
  }
}

/// Realistic list tile skeleton (avatar/icon + 2 text lines + optional trailing).
class SkeletonTile extends StatelessWidget {
  const SkeletonTile({
    super.key,
    this.hasLeadingAvatar = true,
    this.avatarSize = 44,
    this.isAvatarCircle = true,
    this.hasTrailing = false,
    this.trailingWidth = 60,
    this.titleWidth = 140,
    this.subtitleWidth = 200,
  });

  final bool hasLeadingAvatar;
  final double avatarSize;
  final bool isAvatarCircle;
  final bool hasTrailing;
  final double trailingWidth;
  final double titleWidth;
  final double subtitleWidth;

  @override
  Widget build(BuildContext context) {
    final tone = SkeletonShimmer.toneOf(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: tone.cardBackground,
        borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
        border: Border.all(color: tone.borderColor),
      ),
      child: ShimmerLayer(
        child: Row(
          children: [
            if (hasLeadingAvatar) ...[
              SkeletonAvatar(
                size: avatarSize,
                isCircle: isAvatarCircle,
                radius: 12,
              ),
              const SizedBox(width: AppSpacing.md),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SkeletonLine(width: titleWidth, height: 15),
                  const SizedBox(height: 6),
                  SkeletonLine(width: subtitleWidth, height: 12),
                ],
              ),
            ),
            if (hasTrailing) ...[
              const SizedBox(width: AppSpacing.md),
              SkeletonChip(width: trailingWidth, height: 24),
            ],
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SCREEN-SPECIFIC REALISTIC SKELETONS
// -----------------------------------------------------------------------------

/// Realistic UI-matching skeleton for the Home Screen.
class HomeSkeleton extends StatelessWidget {
  const HomeSkeleton({super.key, this.tone = SkeletonTone.grey});
  final SkeletonTone tone;

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      tone: tone,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.sm,
          AppSpacing.page,
          AppSpacing.xxl,
        ),
        physics: const NeverScrollableScrollPhysics(),
        children: [
          // Top bar: Org badge + Bell + Avatar
          ShimmerLayer(
            child: Row(
              children: [
                SkeletonBone(
                  width: 90,
                  height: 28,
                  borderRadius: BorderRadius.circular(8),
                ),
                const Spacer(),
                const SkeletonAvatar(size: 36, isCircle: true),
                const SizedBox(width: AppSpacing.sm),
                const SkeletonAvatar(size: 40, isCircle: true),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),

          // Greeting headline & date
          const ShimmerLayer(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonLine(width: 220, height: 26, borderRadius: 8),
                SizedBox(height: 6),
                SkeletonLine(width: 140, height: 13, borderRadius: 5),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),

          // Hero Shift / Punch Card
          SkeletonCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    SkeletonLine(width: 120, height: 16),
                    Spacer(),
                    SkeletonChip(width: 72, height: 22),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                const Row(
                  children: [
                    SkeletonBone(
                      width: 48,
                      height: 48,
                      borderRadius: BorderRadius.all(Radius.circular(14)),
                    ),
                    SizedBox(width: AppSpacing.md),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonLine(width: 110, height: 22),
                        SizedBox(height: 6),
                        SkeletonLine(width: 160, height: 13),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                SkeletonBone(
                  height: 48,
                  borderRadius: BorderRadius.circular(14),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Quick actions grid (4 icon squircle tiles)
          ShimmerLayer(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(4, (_) {
                return Column(
                  children: [
                    SkeletonBone(
                      width: 64,
                      height: 64,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    const SizedBox(height: 6),
                    const SkeletonLine(width: 52, height: 11),
                  ],
                );
              }),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Pending reviews / tasks card
          SkeletonCard(
            child: Row(
              children: [
                const SkeletonAvatar(
                  size: 42,
                  isCircle: false,
                  radius: 12,
                ),
                const SizedBox(width: AppSpacing.md),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonLine(width: 150, height: 15),
                      SizedBox(height: 6),
                      SkeletonLine(width: 100, height: 12),
                    ],
                  ),
                ),
                const SkeletonChip(width: 56, height: 24),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Payslips card
          SkeletonCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    SkeletonLine(width: 130, height: 16),
                    Spacer(),
                    SkeletonLine(width: 60, height: 13),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    const SkeletonBone(
                      width: 40,
                      height: 40,
                      borderRadius: BorderRadius.all(Radius.circular(10)),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SkeletonLine(width: 120, height: 14),
                          SizedBox(height: 5),
                          SkeletonLine(width: 80, height: 11),
                        ],
                      ),
                    ),
                    SkeletonBone(
                      width: 32,
                      height: 32,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Upcoming holidays card
          const SkeletonCard(
            child: Row(
              children: [
                SkeletonBone(
                  width: 42,
                  height: 42,
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                ),
                SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonLine(width: 140, height: 15),
                      SizedBox(height: 6),
                      SkeletonLine(width: 90, height: 12),
                    ],
                  ),
                ),
                SkeletonChip(width: 60, height: 22),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Realistic UI-matching skeleton for the Attendance Screen.
class AttendanceSkeleton extends StatelessWidget {
  const AttendanceSkeleton({super.key, this.tone = SkeletonTone.grey});
  final SkeletonTone tone;

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      tone: tone,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.sm,
          AppSpacing.page,
          96,
        ),
        physics: const NeverScrollableScrollPhysics(),
        children: [
          // Month navigation bar
          const ShimmerLayer(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SkeletonAvatar(size: 32, isCircle: true),
                SizedBox(width: AppSpacing.md),
                SkeletonLine(width: 140, height: 18),
                SizedBox(width: AppSpacing.md),
                SkeletonAvatar(size: 32, isCircle: true),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // Totals summary card (3 metrics: worked, scheduled, present days)
          SkeletonCard(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: List.generate(3, (i) {
                return const Column(
                  children: [
                    SkeletonLine(width: 54, height: 22),
                    SizedBox(height: 6),
                    SkeletonLine(width: 64, height: 12),
                  ],
                );
              }),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // 5 Attendance day cards
          for (var i = 0; i < 5; i++) ...[
            SkeletonCard(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  // Date box
                  const SkeletonBone(
                    width: 48,
                    height: 48,
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  // Shift hours & punches
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonLine(
                          width: i.isEven ? 130 : 150,
                          height: 15,
                        ),
                        const SizedBox(height: 6),
                        SkeletonLine(
                          width: i.isEven ? 100 : 80,
                          height: 12,
                        ),
                      ],
                    ),
                  ),
                  const SkeletonChip(width: 68, height: 24),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }
}

/// Realistic UI-matching skeleton for the Leave Screen.
class LeaveSkeleton extends StatelessWidget {
  const LeaveSkeleton({super.key, this.tone = SkeletonTone.grey});
  final SkeletonTone tone;

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      tone: tone,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.sm,
          AppSpacing.page,
          96,
        ),
        physics: const NeverScrollableScrollPhysics(),
        children: [
          // Year switcher
          const ShimmerLayer(
            child: Center(
              child: SkeletonBone(
                width: 160,
                height: 32,
                borderRadius: BorderRadius.all(Radius.circular(999)),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // 2 Leave balance cards side-by-side
          Row(
            children: [
              Expanded(
                child: SkeletonCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Expanded(child: SkeletonLine(width: 64, height: 14)),
                          SkeletonChip(width: 36, height: 18),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const SkeletonLine(width: 50, height: 26),
                      const SizedBox(height: 8),
                      SkeletonBone(
                        height: 6,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: SkeletonCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Expanded(child: SkeletonLine(width: 64, height: 14)),
                          SkeletonChip(width: 36, height: 18),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const SkeletonLine(width: 50, height: 26),
                      const SizedBox(height: 8),
                      SkeletonBone(
                        height: 6,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),

          // Section header: Requests
          const ShimmerLayer(
            child: SkeletonLine(width: 140, height: 18),
          ),
          const SizedBox(height: AppSpacing.md),

          // 3 Request items
          for (var i = 0; i < 3; i++) ...[
            SkeletonCard(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  const SkeletonBone(
                    width: 44,
                    height: 44,
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonLine(
                          width: i == 0 ? 120 : 150,
                          height: 15,
                        ),
                        const SizedBox(height: 6),
                        const SkeletonLine(width: 170, height: 12),
                      ],
                    ),
                  ),
                  const SkeletonChip(width: 64, height: 22),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }
}

/// Realistic UI-matching skeleton for People & Employees Directory screens.
class PeopleSkeleton extends StatelessWidget {
  const PeopleSkeleton({super.key, this.tone = SkeletonTone.grey});
  final SkeletonTone tone;

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      tone: tone,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.page),
        physics: const NeverScrollableScrollPhysics(),
        children: [
          // Search input bar
          const ShimmerLayer(
            child: SkeletonBone(
              height: 48,
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // Filter chips row
          const ShimmerLayer(
            child: Row(
              children: [
                SkeletonChip(width: 80, height: 32),
                SizedBox(width: AppSpacing.sm),
                SkeletonChip(width: 110, height: 32),
                SizedBox(width: AppSpacing.sm),
                SkeletonChip(width: 90, height: 32),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // 6 PersonTiles with circular avatar + name + designation
          for (var i = 0; i < 6; i++) ...[
            SkeletonTile(
              avatarSize: 44,
              isAvatarCircle: true,
              titleWidth: i.isEven ? 140 : 160,
              subtitleWidth: i.isEven ? 200 : 170,
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }
}

/// Realistic UI-matching skeleton for My Profile & Employee Detail screens.
class ProfileSkeleton extends StatelessWidget {
  const ProfileSkeleton({super.key, this.tone = SkeletonTone.grey});
  final SkeletonTone tone;

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      tone: tone,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.page),
        physics: const NeverScrollableScrollPhysics(),
        children: [
          // Hero Profile Card (large 72px avatar + name + designation + role chips)
          SkeletonCard(
            child: Row(
              children: [
                const SkeletonAvatar(size: 72, isCircle: true),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SkeletonLine(width: 150, height: 20),
                      const SizedBox(height: 6),
                      const SkeletonLine(width: 190, height: 14),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const SkeletonChip(width: 60, height: 22),
                          const SizedBox(width: 6),
                          SkeletonBone(
                            width: 70,
                            height: 22,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Contact Details Section Card
          SkeletonCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SkeletonLine(width: 120, height: 16),
                const SizedBox(height: AppSpacing.lg),
                for (var i = 0; i < 3; i++) ...[
                  Row(
                    children: [
                      SkeletonLine(
                        width: i == 0 ? 80 : 100,
                        height: 13,
                      ),
                      const Spacer(),
                      SkeletonLine(
                        width: i == 0 ? 150 : 120,
                        height: 14,
                      ),
                    ],
                  ),
                  if (i < 2) const SizedBox(height: AppSpacing.md),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Shift & Reporting Section Card
          SkeletonCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SkeletonLine(width: 130, height: 16),
                const SizedBox(height: AppSpacing.lg),
                for (var i = 0; i < 2; i++) ...[
                  Row(
                    children: [
                      SkeletonLine(
                        width: i == 0 ? 90 : 70,
                        height: 13,
                      ),
                      const Spacer(),
                      SkeletonLine(
                        width: i == 0 ? 130 : 110,
                        height: 14,
                      ),
                    ],
                  ),
                  if (i < 1) const SizedBox(height: AppSpacing.md),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Realistic UI-matching skeleton for My Requests & Review Queue screens.
class RequestsSkeleton extends StatelessWidget {
  const RequestsSkeleton({super.key, this.tone = SkeletonTone.grey});
  final SkeletonTone tone;

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      tone: tone,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.page),
        physics: const NeverScrollableScrollPhysics(),
        children: [
          // Filter pill tabs row
          const ShimmerLayer(
            child: Row(
              children: [
                SkeletonChip(width: 50, height: 34),
                SizedBox(width: AppSpacing.sm),
                SkeletonChip(width: 75, height: 34),
                SizedBox(width: AppSpacing.sm),
                SkeletonChip(width: 95, height: 34),
                SizedBox(width: AppSpacing.sm),
                SkeletonChip(width: 70, height: 34),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // 5 Request tiles
          for (var i = 0; i < 5; i++) ...[
            SkeletonCard(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  const SkeletonBone(
                    width: 44,
                    height: 44,
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonLine(
                          width: i % 2 == 0 ? 140 : 170,
                          height: 15,
                        ),
                        const SizedBox(height: 6),
                        SkeletonLine(
                          width: i % 2 == 0 ? 180 : 130,
                          height: 12,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  const SkeletonChip(width: 70, height: 24),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }
}

/// Realistic UI-matching skeleton for Request Details & Approval Details.
class RequestDetailSkeleton extends StatelessWidget {
  const RequestDetailSkeleton({super.key, this.tone = SkeletonTone.grey});
  final SkeletonTone tone;

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      tone: tone,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.page),
        physics: const NeverScrollableScrollPhysics(),
        children: [
          // Status Header Card
          SkeletonCard(
            child: Row(
              children: [
                const SkeletonBone(
                  width: 48,
                  height: 48,
                  borderRadius: BorderRadius.all(Radius.circular(14)),
                ),
                const SizedBox(width: AppSpacing.md),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonLine(width: 150, height: 18),
                      SizedBox(height: 6),
                      SkeletonLine(width: 110, height: 12),
                    ],
                  ),
                ),
                const SkeletonChip(width: 76, height: 26),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Request Details Card
          SkeletonCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SkeletonLine(width: 120, height: 16),
                const SizedBox(height: AppSpacing.lg),
                for (var i = 0; i < 4; i++) ...[
                  Row(
                    children: [
                      SkeletonLine(width: i.isEven ? 80 : 100, height: 13),
                      const Spacer(),
                      SkeletonLine(width: i.isEven ? 140 : 110, height: 14),
                    ],
                  ),
                  if (i < 3) const SizedBox(height: AppSpacing.md),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Timeline steps card
          SkeletonCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SkeletonLine(width: 110, height: 16),
                const SizedBox(height: AppSpacing.lg),
                for (var i = 0; i < 2; i++) ...[
                  Row(
                    children: [
                      const SkeletonAvatar(size: 20, isCircle: true),
                      const SizedBox(width: AppSpacing.md),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SkeletonLine(width: i == 0 ? 120 : 140, height: 14),
                          const SizedBox(height: 4),
                          const SkeletonLine(width: 80, height: 11),
                        ],
                      ),
                    ],
                  ),
                  if (i < 1) const SizedBox(height: AppSpacing.md),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Realistic UI-matching skeleton for the Payslips Screen.
class PayslipsSkeleton extends StatelessWidget {
  const PayslipsSkeleton({super.key, this.tone = SkeletonTone.grey});
  final SkeletonTone tone;

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      tone: tone,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.page),
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (var i = 0; i < 4; i++) ...[
            SkeletonCard(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  const SkeletonBone(
                    width: 44,
                    height: 44,
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonLine(
                          width: i.isEven ? 120 : 140,
                          height: 16,
                        ),
                        const SizedBox(height: 6),
                        const SkeletonLine(width: 90, height: 12),
                      ],
                    ),
                  ),
                  const SkeletonAvatar(size: 36, isCircle: true),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }
}

/// Realistic UI-matching skeleton for Documents & Policies screens.
class DocumentsSkeleton extends StatelessWidget {
  const DocumentsSkeleton({super.key, this.tone = SkeletonTone.grey});
  final SkeletonTone tone;

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      tone: tone,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.page),
        physics: const NeverScrollableScrollPhysics(),
        children: [
          const ShimmerLayer(
            child: SkeletonLine(width: 150, height: 16),
          ),
          const SizedBox(height: AppSpacing.md),
          for (var i = 0; i < 2; i++) ...[
            SkeletonCard(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  const SkeletonBone(
                    width: 40,
                    height: 40,
                    borderRadius: BorderRadius.all(Radius.circular(10)),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonLine(
                          width: i == 0 ? 170 : 140,
                          height: 15,
                        ),
                        const SizedBox(height: 6),
                        const SkeletonLine(width: 90, height: 11),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          const SizedBox(height: AppSpacing.lg),
          const ShimmerLayer(
            child: SkeletonLine(width: 130, height: 16),
          ),
          const SizedBox(height: AppSpacing.md),
          for (var i = 0; i < 2; i++) ...[
            SkeletonCard(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  const SkeletonBone(
                    width: 40,
                    height: 40,
                    borderRadius: BorderRadius.all(Radius.circular(10)),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonLine(
                          width: i == 0 ? 130 : 160,
                          height: 15,
                        ),
                        const SizedBox(height: 6),
                        const SkeletonLine(width: 80, height: 11),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }
}

/// Realistic UI-matching skeleton for Workspace Screen.
class WorkspaceSkeleton extends StatelessWidget {
  const WorkspaceSkeleton({super.key, this.tone = SkeletonTone.grey});
  final SkeletonTone tone;

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      tone: tone,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.page),
        physics: const NeverScrollableScrollPhysics(),
        children: [
          const ShimmerLayer(
            child: SkeletonLine(width: 140, height: 14),
          ),
          const SizedBox(height: AppSpacing.md),

          // Team Today Card with Avatars
          SkeletonCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SkeletonLine(width: 110, height: 16),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    for (var i = 0; i < 4; i++) ...[
                      const SkeletonAvatar(size: 38, isCircle: true),
                      const SizedBox(width: 8),
                    ],
                    const Spacer(),
                    const SkeletonChip(width: 60, height: 24),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Weekly totals card
          SkeletonCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SkeletonLine(width: 130, height: 16),
                const SizedBox(height: AppSpacing.md),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: List.generate(3, (_) {
                    return const Column(
                      children: [
                        SkeletonLine(width: 50, height: 20),
                        SizedBox(height: 4),
                        SkeletonLine(width: 60, height: 12),
                      ],
                    );
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Storage Budget Card
          SkeletonCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    SkeletonLine(width: 120, height: 16),
                    Spacer(),
                    SkeletonLine(width: 40, height: 14),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                SkeletonBone(
                  height: 8,
                  borderRadius: BorderRadius.circular(999),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Realistic UI-matching skeleton for Settings Screen.
class SettingsSkeleton extends StatelessWidget {
  const SettingsSkeleton({super.key, this.tone = SkeletonTone.grey});
  final SkeletonTone tone;

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      tone: tone,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.page),
        physics: const NeverScrollableScrollPhysics(),
        children: [
          // Profile summary tile
          SkeletonCard(
            child: Row(
              children: [
                const SkeletonAvatar(size: 48, isCircle: true),
                const SizedBox(width: AppSpacing.md),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonLine(width: 140, height: 16),
                      SizedBox(height: 6),
                      SkeletonLine(width: 180, height: 12),
                    ],
                  ),
                ),
                SkeletonBone(
                  width: 24,
                  height: 24,
                  borderRadius: BorderRadius.circular(6),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Grouped settings card
          SkeletonCard(
            child: Column(
              children: [
                for (var i = 0; i < 3; i++) ...[
                  Row(
                    children: [
                      SkeletonBone(
                        width: 28,
                        height: 28,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      SkeletonLine(
                        width: i == 0 ? 140 : (i == 1 ? 110 : 160),
                        height: 15,
                      ),
                      const Spacer(),
                      SkeletonBone(
                        width: 44,
                        height: 24,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ],
                  ),
                  if (i < 2) const SizedBox(height: AppSpacing.lg),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Device card
          SkeletonCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SkeletonLine(width: 130, height: 16),
                const SizedBox(height: AppSpacing.md),
                for (var i = 0; i < 3; i++) ...[
                  Row(
                    children: [
                      SkeletonLine(width: 80, height: 13),
                      const Spacer(),
                      SkeletonLine(width: 120, height: 13),
                    ],
                  ),
                  if (i < 2) const SizedBox(height: AppSpacing.md),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
