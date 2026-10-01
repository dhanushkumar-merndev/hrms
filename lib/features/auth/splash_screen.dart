import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/auth/session_controller.dart';

/// Startup / reconnect screen while the session is being validated: the brand
/// star pops in on a white disc with soft ripples, the name slides up, and a
/// slim bar shows progress. Motion is skipped when the phone asks for less.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> with TickerProviderStateMixin {
  static const _brandRed = Color(0xFFEA0208);

  late final AnimationController _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  late final AnimationController _ripple = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));

  late final Animation<double> _logoScale =
      CurvedAnimation(parent: _intro, curve: const Interval(0, 0.7, curve: Curves.easeOutBack));
  late final Animation<double> _logoFade = CurvedAnimation(parent: _intro, curve: const Interval(0, 0.4));
  late final Animation<double> _textFade = CurvedAnimation(parent: _intro, curve: const Interval(0.45, 1));
  late final Animation<Offset> _textSlide = Tween(begin: const Offset(0, 0.4), end: Offset.zero)
      .animate(CurvedAnimation(parent: _intro, curve: const Interval(0.45, 1, curve: Curves.easeOutCubic)));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _intro.value = 1;
      _ripple.stop();
    } else {
      if (_intro.status == AnimationStatus.dismissed) _intro.forward();
      if (!_ripple.isAnimating) _ripple.repeat();
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sessionProvider);
    final unreachable = state.phase == SessionPhase.unreachable;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: 180,
              height: 180,
              child: Stack(alignment: Alignment.center, children: [
                // Two rings half a cycle apart, growing and fading out.
                for (final phase in const [0.0, 0.5])
                  AnimatedBuilder(
                    animation: _ripple,
                    builder: (context, _) {
                      if (!_ripple.isAnimating) return const SizedBox.shrink();
                      final v = (_ripple.value + phase) % 1;
                      return Container(
                        width: 120 + 60 * v,
                        height: 120 + 60 * v,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: _brandRed.withValues(alpha: 0.28 * (1 - v)), width: 2),
                        ),
                      );
                    },
                  ),
                FadeTransition(
                  opacity: _logoFade,
                  child: ScaleTransition(
                    scale: _logoScale,
                    child: Container(
                      width: 120,
                      height: 120,
                      padding: const EdgeInsets.all(22),
                      decoration: const BoxDecoration(
                        color: AppColors.surface,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(color: Color(0x26263342), blurRadius: 24, offset: Offset(0, 10), spreadRadius: -4),
                        ],
                      ),
                      child: Image.asset('assets/brand/logo.png', semanticLabel: 'Internal HRMS logo'),
                    ),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: AppSpacing.lg),
            FadeTransition(
              opacity: _textFade,
              child: SlideTransition(
                position: _textSlide,
                child: Column(children: [
                  Text('Internal HRMS',
                      style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: AppColors.text)),
                  const SizedBox(height: 4),
                  Text('Attendance · Leave · Pay', style: t.bodyMedium?.copyWith(color: AppColors.textSecondary)),
                ]),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            if (!unreachable)
              SizedBox(
                width: 140,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: const LinearProgressIndicator(
                    minHeight: 4,
                    backgroundColor: AppColors.border,
                    valueColor: AlwaysStoppedAnimation(_brandRed),
                  ),
                ),
              )
            else ...[
              Text('Can\'t reach the server', style: t.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              Text(state.message ?? 'Check your connection and try again.',
                  textAlign: TextAlign.center, style: t.bodyMedium),
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
