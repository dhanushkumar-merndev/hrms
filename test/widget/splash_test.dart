import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/app/theme.dart';
import 'package:hrms/core/auth/session_controller.dart';
import 'package:hrms/features/auth/splash_screen.dart';

class _PhaseSession extends SessionController {
  _PhaseSession(this.phase);
  final SessionPhase phase;
  int refreshes = 0;

  @override
  SessionState build() => SessionState(phase);

  @override
  Future<void> refreshContext() async => refreshes++;
}

Future<_PhaseSession> _pump(WidgetTester tester, SessionPhase phase) async {
  final session = _PhaseSession(phase);
  await tester.pumpWidget(ProviderScope(
    overrides: [sessionProvider.overrideWith(() => session)],
    child: MaterialApp(theme: buildTheme(), home: const SplashScreen()),
  ));
  // Pump once to render the screen.
  await tester.pump();
  return session;
}

void main() {
  testWidgets('SPLASH-001 shows the brand logo while connecting', (tester) async {
    await _pump(tester, SessionPhase.loading);
    expect(find.bySemanticsLabel('Internal HRMS logo'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Try again'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('SPLASH-002 offline: explains and retries', (tester) async {
    final session = await _pump(tester, SessionPhase.unreachable);
    expect(find.text('Can\'t reach the server'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.tap(find.text('Try again'));
    expect(session.refreshes, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
