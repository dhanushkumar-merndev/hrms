import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/features/attendance/punch_screen.dart';
import 'package:hrms/features/attendance/wifi_evidence.dart';

void main() {
  Future<void> pumpEvidence(WidgetTester tester, WifiEvidence evidence) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WifiEvidenceStatus(evidence: evidence)),
      ),
    );
  }

  testWidgets('connected office Wi-Fi is labelled as connected', (
    tester,
  ) async {
    await pumpEvidence(
      tester,
      const WifiEvidence(WifiEvidenceMode.connected, matchedSsid: 'Office'),
    );
    expect(find.text('Connected to office Wi-Fi: Office'), findsOneWidget);
  });

  testWidgets('nearby evidence never claims the phone is connected', (
    tester,
  ) async {
    await pumpEvidence(
      tester,
      const WifiEvidence(WifiEvidenceMode.nearby, matchedSsid: 'Office'),
    );
    expect(
      find.text(
        'Office Wi-Fi detected nearby: Office — mobile data is allowed.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Connected to office Wi-Fi'), findsNothing);
  });

  testWidgets('missing office Wi-Fi explains how to refresh', (tester) async {
    await pumpEvidence(tester, const WifiEvidence(WifiEvidenceMode.missing));
    expect(
      find.text('Office Wi-Fi not detected. Turn on Wi-Fi and refresh.'),
      findsOneWidget,
    );
  });
}
