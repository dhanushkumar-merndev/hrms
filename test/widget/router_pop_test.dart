// ROUTE-001: returning from a pushed screen reports its result, so lists
// that reload on return (reviews, employees, requests) refresh.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hrms/app/shell.dart';

GoRouter _router(List<String> log, {required bool swipe, Listenable? refresh}) => GoRouter(
      initialLocation: '/home',
      refreshListenable: refresh,
      redirect: (_, _) => null,
      routes: [
        StatefulShellRoute(
          builder: (c, s, shell) => AppShell(shell: shell),
          navigatorContainerBuilder: (c, shell, children) =>
              swipe ? SwipeTabs(shell: shell, children: children) : children[shell.currentIndex],
          branches: [
            StatefulShellBranch(preload: true, routes: [
              GoRoute(path: '/home', builder: (c, _) => Scaffold(body: TextButton(
                  onPressed: () => c.push('/list'), child: const Text('open list')))),
            ]),
            StatefulShellBranch(preload: true, routes: [GoRoute(path: '/action', builder: (_, _) => const Text('a'))]),
            StatefulShellBranch(preload: true, routes: [GoRoute(path: '/explore', builder: (_, _) => const Text('e'))]),
          ],
        ),
        GoRoute(path: '/list', builder: (c, _) => Scaffold(body: TextButton(
            onPressed: () => c.push('/detail').then((v) => log.add('returned $v')), child: const Text('open detail')))),
        GoRoute(path: '/detail', builder: (c, _) => Scaffold(body: TextButton(
            onPressed: () => c.pop(true), child: const Text('approve')))),
      ],
    );

void main() {
  for (final swipe in [false, true]) {
    testWidgets('push().then fires after context.pop (swipe tabs: $swipe)', (tester) async {
      final log = <String>[];
      await tester.pumpWidget(MaterialApp.router(routerConfig: _router(log, swipe: swipe)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open list'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open detail'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('approve'));
      await tester.pumpAndSettle();
      expect(log, ['returned true']);
      expect(find.text('open detail'), findsOneWidget);
    });
  }
}
