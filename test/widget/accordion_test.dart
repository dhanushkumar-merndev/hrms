import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/app/theme.dart';
import 'package:hrms/core/widgets/accordion.dart';

class _Two extends StatefulWidget {
  const _Two();
  @override
  State<_Two> createState() => _TwoState();
}

class _TwoState extends State<_Two> {
  String? open = 'a';
  void toggle(String k) => setState(() => open = open == k ? null : k);

  @override
  Widget build(BuildContext context) => ListView(children: [
        AccordionSection(
          title: 'Employment',
          icon: Icons.badge_outlined,
          summary: 'QA Dept',
          expanded: open == 'a',
          onToggle: () => toggle('a'),
          action: TextButton(onPressed: () {}, child: const Text('Edit')),
          child: const Text('body A'),
        ),
        AccordionSection(
          title: 'Team',
          icon: Icons.groups_outlined,
          summary: 'QA Team',
          expanded: open == 'b',
          onToggle: () => toggle('b'),
          child: const Text('body B'),
        ),
      ]);
}

void main() {
  testWidgets('ACC-001 one section open at a time; closed bodies are not built; action only while open',
      (tester) async {
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const Scaffold(body: _Two())));
    expect(find.text('body A'), findsOneWidget);
    expect(find.text('body B'), findsNothing);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('QA Team'), findsOneWidget, reason: 'summary visible while closed');

    await tester.tap(find.text('Team'));
    await tester.pumpAndSettle();
    expect(find.text('body B'), findsOneWidget);
    expect(find.text('body A'), findsNothing);
    expect(find.text('Edit'), findsNothing);

    await tester.tap(find.text('Team'));
    await tester.pumpAndSettle();
    expect(find.text('body B'), findsNothing);
  });
}
