import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hrms/app/material_route.dart';
import 'package:hrms/app/theme.dart';

void main() {
  testWidgets('pushes with slide from right to left, pops with slide to right', (tester) async {
    final theme = buildTheme();

    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => Scaffold(
                      appBar: AppBar(title: const Text('Detail Screen')),
                      body: Center(
                        child: ElevatedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Go Back'),
                        ),
                      ),
                    ),
                  ),
                );
              },
              child: const Text('Open Detail'),
            ),
          ),
        ),
      ),
    ));

    expect(find.text('Open Detail'), findsOneWidget);
    expect(find.text('Detail Screen'), findsNothing);

    // Tap to push detail screen
    await tester.tap(find.text('Open Detail'));
    await tester.pump(); // Start transition

    // Mid-push (e.g. 150ms into 300ms transition)
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Detail Screen'), findsOneWidget);

    // Find the SlideTransition widget for the entering screen
    final slideTransitions = tester.widgetList<SlideTransition>(find.byType(SlideTransition));
    expect(slideTransitions, isNotEmpty);

    // Complete the push transition
    await tester.pumpAndSettle();
    expect(find.text('Detail Screen'), findsOneWidget);
    expect(find.text('Go Back'), findsOneWidget);

    // Tap to pop back
    await tester.tap(find.text('Go Back'));
    await tester.pump(); // Start pop

    // Mid-pop: screen is sliding to the right
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Detail Screen'), findsOneWidget);

    // Complete the pop transition
    await tester.pumpAndSettle();
    expect(find.text('Detail Screen'), findsNothing);
    expect(find.text('Open Detail'), findsOneWidget);
  });

  // go_router 18 detects the material_ui MaterialApp, not flutter/material's,
  // so plain `builder:` routes got a zero-duration NoTransitionPage and every
  // screen snapped in. AppRoute must keep the themed slide.
  testWidgets('AppRoute pages slide in through go_router', (tester) async {
    final router = GoRouter(routes: [
      AppRoute(path: '/', builder: (c, _) => Scaffold(body: TextButton(onPressed: () => c.push('/b'), child: const Text('open')))),
      AppRoute(path: '/b', builder: (_, _) => const Scaffold(body: Text('B'))),
    ]);
    await tester.pumpWidget(MaterialApp.router(theme: buildTheme(), routerConfig: router));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    final route = ModalRoute.of(tester.element(find.text('B')))! as TransitionRoute;
    expect(route.transitionDuration, greaterThan(Duration.zero));
    final dx = tester
        .widgetList<SlideTransition>(find.ancestor(of: find.text('B'), matching: find.byType(SlideTransition)))
        .map((w) => w.position.value.dx);
    expect(dx.any((v) => v > 0.05), isTrue, reason: 'new page should still be sliding in');
    await tester.pumpAndSettle();
  });

  // go_router 18 detects the material_ui MaterialApp, not flutter/material's,
  // so plain `builder:` routes got a zero-duration NoTransitionPage and every
  // screen snapped in. AppRoute must keep the themed slide.
  testWidgets('AppRoute pages slide in through go_router', (tester) async {
    final router = GoRouter(routes: [
      AppRoute(path: '/', builder: (c, _) => Scaffold(body: TextButton(onPressed: () => c.push('/b'), child: const Text('open')))),
      AppRoute(path: '/b', builder: (_, _) => const Scaffold(body: Text('B'))),
    ]);
    await tester.pumpWidget(MaterialApp.router(theme: buildTheme(), routerConfig: router));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    final route = ModalRoute.of(tester.element(find.text('B')))! as TransitionRoute;
    expect(route.transitionDuration, greaterThan(Duration.zero));
    final dx = tester
        .widgetList<SlideTransition>(find.ancestor(of: find.text('B'), matching: find.byType(SlideTransition)))
        .map((w) => w.position.value.dx);
    expect(dx.any((v) => v > 0.05), isTrue, reason: 'new page should still be sliding in');
    await tester.pumpAndSettle();
  });
}
