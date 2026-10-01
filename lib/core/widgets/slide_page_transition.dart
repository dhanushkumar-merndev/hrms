import 'package:flutter/material.dart';

/// A lightweight slide transition that only composites the moving page.
/// Push enters from the right; pop exits to the right.
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
      child: child,
    );
  }
}

class _SlideRightLeftTransition extends StatelessWidget {
  const _SlideRightLeftTransition({
    required this.animation,
    required this.child,
  });

  final Animation<double> animation;
  final Widget child;

  static final Animatable<Offset> _primarySlide = Tween<Offset>(
    begin: const Offset(1.0, 0.0),
    end: Offset.zero,
  ).chain(CurveTween(curve: Curves.easeOutCubic));

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) return child;

    // A transform-only transition stays on the compositor thread. Avoid
    // animating a full-screen blur, scrim, or the page underneath: those
    // effects caused repeated raster work and visible jank on older phones.
    return SlideTransition(
      position: _primarySlide.animate(animation),
      child: RepaintBoundary(child: child),
    );
  }
}
