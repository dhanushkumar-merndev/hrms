import 'package:flutter/material.dart';

/// A high-performance, GPU-optimized slide page transition builder.
///
/// - On Push: The entering screen slides in from Right to Left (`1.0 -> 0.0`)
///   with smooth [Curves.easeOutCubic] easing and an edge drop-shadow.
///   The underlying screen parallax-shifts slightly to the left (`0.0 -> -0.25`)
///   with a gentle scrim.
/// - On Pop: The screen slides out from Left to Right (`0.0 -> 1.0`),
///   revealing the previous screen sliding back into place.
class SlideRightLeftPageTransitionsBuilder extends PageTransitionsBuilder {
  const SlideRightLeftPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _SlideRightLeftTransition(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      child: child,
    );
  }
}

class _SlideRightLeftTransition extends StatelessWidget {
  const _SlideRightLeftTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  static final Animatable<Offset> _primarySlide = Tween<Offset>(
    begin: const Offset(1.0, 0.0),
    end: Offset.zero,
  ).chain(CurveTween(curve: Curves.easeOutCubic));

  static final Animatable<Offset> _secondarySlide = Tween<Offset>(
    begin: Offset.zero,
    end: const Offset(-0.25, 0.0),
  ).chain(CurveTween(curve: Curves.easeOutCubic));

  static final Animatable<double> _secondaryScrim = Tween<double>(
    begin: 0.0,
    end: 0.10,
  ).chain(CurveTween(curve: Curves.easeOutCubic));

  @override
  Widget build(BuildContext context) {
    // Parallax slide and dimming for when another screen is pushed on top of this one
    return SlideTransition(
      position: _secondarySlide.animate(secondaryAnimation),
      child: AnimatedBuilder(
        animation: secondaryAnimation,
        builder: (context, currentChild) {
          final scrim = _secondaryScrim.evaluate(secondaryAnimation);
          if (scrim <= 0.001) return currentChild!;
          return ColoredBox(
            color: Colors.black.withValues(alpha: scrim),
            child: currentChild,
          );
        },
        // The primary entering/exiting screen with edge drop shadow
        child: SlideTransition(
          position: _primarySlide.animate(animation),
          child: RepaintBoundary(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                boxShadow: [
                  BoxShadow(
                    color: Color(0x1A000000),
                    blurRadius: 18.0,
                    offset: Offset(-3.0, 0.0),
                  ),
                ],
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
