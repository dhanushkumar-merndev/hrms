import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/core/widgets/jelly_nav_bar.dart';

void main() {
  Widget buildTestBar({
    required int selectedIndex,
    required ValueChanged<int> onDestinationSelected,
  }) {
    return MaterialApp(
      home: Scaffold(
        bottomNavigationBar: JellyNavigationBar(
          selectedIndex: selectedIndex,
          onDestinationSelected: onDestinationSelected,
          destinations: const [
            JellyNavDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            JellyNavDestination(
              icon: Icon(Icons.bolt_outlined),
              selectedIcon: Icon(Icons.bolt_rounded),
              label: 'Action',
            ),
            JellyNavDestination(
              icon: Icon(Icons.grid_view_outlined),
              selectedIcon: Icon(Icons.grid_view_rounded),
              label: 'Explore',
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('renders all 3 destinations with labels and icons', (tester) async {
    await tester.pumpWidget(buildTestBar(
      selectedIndex: 0,
      onDestinationSelected: (_) {},
    ));

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Action'), findsOneWidget);
    expect(find.text('Explore'), findsOneWidget);
    expect(find.byIcon(Icons.home_rounded), findsOneWidget);
    expect(find.byIcon(Icons.bolt_outlined), findsOneWidget);
    expect(find.byIcon(Icons.grid_view_outlined), findsOneWidget);
  });

  testWidgets('tapping destination triggers onDestinationSelected and animates smoothly', (tester) async {
    int selected = 0;
    await tester.pumpWidget(StatefulBuilder(
      builder: (context, setState) {
        return buildTestBar(
          selectedIndex: selected,
          onDestinationSelected: (i) => setState(() => selected = i),
        );
      },
    ));

    // Tap 'Action' (index 1)
    await tester.tap(find.text('Action'));
    await tester.pump(); // Start animation
    expect(selected, 1);

    // Pump halfway through jelly motion
    await tester.pump(const Duration(milliseconds: 190));

    // Pump to completion
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);

    // Tap 'Explore' (index 2)
    await tester.tap(find.text('Explore'));
    await tester.pump();
    expect(selected, 2);

    await tester.pump(const Duration(milliseconds: 190));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.grid_view_rounded), findsOneWidget);

    // Tap 'Home' (index 0 - multi-step reverse jump)
    await tester.tap(find.text('Home'));
    await tester.pump();
    expect(selected, 0);

    await tester.pump(const Duration(milliseconds: 190));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.home_rounded), findsOneWidget);
  });

  testWidgets('tapping current tab triggers in-place jelly squish bounce', (tester) async {
    int tappedIndex = -1;
    await tester.pumpWidget(buildTestBar(
      selectedIndex: 1,
      onDestinationSelected: (i) => tappedIndex = i,
    ));

    // Tap 'Action' which is already selected (index 1)
    await tester.tap(find.text('Action'));
    await tester.pump();
    expect(tappedIndex, 1);

    // Mid-bounce
    await tester.pump(const Duration(milliseconds: 100));
    // Settle bounce
    await tester.pumpAndSettle();
  });

  testWidgets('rapid taps interrupt and smoothly transition without glitching', (tester) async {
    int selected = 0;
    await tester.pumpWidget(StatefulBuilder(
      builder: (context, setState) {
        return buildTestBar(
          selectedIndex: selected,
          onDestinationSelected: (i) => setState(() => selected = i),
        );
      },
    ));

    // Tap Explore
    await tester.tap(find.text('Explore'));
    await tester.pump(const Duration(milliseconds: 80));

    // Rapidly tap Action mid-flight
    await tester.tap(find.text('Action'));
    await tester.pump(const Duration(milliseconds: 50));

    // Rapidly tap Home
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();

    expect(selected, 0);
    expect(find.byIcon(Icons.home_rounded), findsOneWidget);
  });
}
