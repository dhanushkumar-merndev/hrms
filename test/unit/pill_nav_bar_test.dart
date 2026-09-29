import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/app/shell.dart';

void main() {
  testWidgets('PillBounceNavBar renders destinations and handles taps with bounce effect',
      (tester) async {
    int selectedIndex = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            return Scaffold(
              bottomNavigationBar: PillBounceNavBar(
                currentIndex: selectedIndex,
                onTap: (i) {
                  setState(() {
                    selectedIndex = i;
                  });
                },
                items: const [
                  PillNavItem(
                    icon: Icons.home_outlined,
                    selectedIcon: Icons.home_rounded,
                    label: 'Home',
                  ),
                  PillNavItem(
                    icon: Icons.bolt_outlined,
                    selectedIcon: Icons.bolt_rounded,
                    label: 'Action',
                  ),
                  PillNavItem(
                    icon: Icons.grid_view_outlined,
                    selectedIcon: Icons.grid_view_rounded,
                    label: 'Explore',
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );

    // Initial state: Home is selected, so 'Home' label is displayed
    expect(find.text('Home'), findsOneWidget);
    expect(selectedIndex, 0);

    // Tap on Action tab
    await tester.tap(find.byIcon(Icons.bolt_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(selectedIndex, 1);
    expect(find.text('Action'), findsOneWidget);

    // Tap on Explore tab
    await tester.tap(find.byIcon(Icons.grid_view_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(selectedIndex, 2);
    expect(find.text('Explore'), findsOneWidget);
  });
}
