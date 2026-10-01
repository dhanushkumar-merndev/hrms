import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/features/documents/documents_screen.dart';

import 'support.dart';

Map<String, dynamic> _doc(String id, String title, {bool mine = true}) => {
      'record_id': id,
      'title': title,
      'file_version_id': 'v$id',
      'state': 'published',
      'mime': 'application/pdf',
      'size_bytes': 120000,
      'document_date': '2026-09-30',
      'added_by_me': mine,
      'can_edit': mine,
    };

Map<String, dynamic> _list(List<Map<String, dynamic>> mine, {int? count}) => {
      'company': const [],
      'mine': mine,
      'count': count ?? mine.length,
      'limit': 10,
      'title_max': 50,
      'can_upload': true,
    };

void main() {
  testWidgets('DOC-UI-001 shows the slot count; only own uploads get Rename/Remove', (tester) async {
    await pumpScreen(tester, const DocumentsScreen(),
        session: testSession(),
        handler: (fn, _) => fn == 'list_my_documents'
            ? _list([_doc('1', 'Aadhaar card'), _doc('2', 'Offer letter', mine: false)])
            : null);
    expect(find.text('2 of 10'), findsOneWidget);
    expect(find.text('Aadhaar card'), findsOneWidget);
    expect(find.textContaining('Added by HR'), findsOneWidget);
    expect(find.byType(DocumentMenu), findsOneWidget, reason: 'HR-added document has no menu');
    final add = tester.widget<FilledButton>(find.ancestor(of: find.text('Upload PDF'), matching: find.byType(FilledButton)));
    expect(add.onPressed, isNotNull);
    await unmount(tester);
  });

  testWidgets('DOC-UI-002 at 10 of 10 the add button is disabled and explains why', (tester) async {
    await pumpScreen(tester, const DocumentsScreen(),
        session: testSession(),
        handler: (fn, _) =>
            fn == 'list_my_documents' ? _list([for (var i = 0; i < 10; i++) _doc('$i', 'Doc $i')]) : null);
    expect(find.text('10 of 10'), findsOneWidget);
    final add = tester.widget<FilledButton>(find.ancestor(of: find.text('Upload PDF'), matching: find.byType(FilledButton)));
    expect(add.onPressed, isNull);
    expect(find.textContaining('Remove a document to add another'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('DOC-UI-003 rename needs a name and caps it at 50 characters', (tester) async {
    final api = await pumpScreen(tester, const DocumentsScreen(),
        session: testSession(),
        handler: (fn, _) => switch (fn) {
              'list_my_documents' => _list([_doc('1', 'Aadhaar card')]),
              'rename_employee_document' => {'record_id': '1', 'title': 'x'},
              _ => null,
            });
    await tester.tap(find.byType(DocumentMenu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Give the document a name'), findsOneWidget);
    expect(api.names, isNot(contains('rename_employee_document')));

    await tester.enterText(find.byType(TextField), 'A' * 70);
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text.length, 50);
    expect(find.text('50/50'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '  PAN card  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final call = api.calls.lastWhere((c) => c.$1 == 'rename_employee_document');
    expect(call.$2, {'p_record_id': '1', 'p_title': 'PAN card'});
    await unmount(tester);
  });

  testWidgets('DOC-UI-004 remove asks first and then calls the server', (tester) async {
    final api = await pumpScreen(tester, const DocumentsScreen(),
        session: testSession(),
        handler: (fn, _) => switch (fn) {
              'list_my_documents' => _list([_doc('1', 'Aadhaar card')]),
              'remove_employee_document' => {'record_id': '1', 'count': 0},
              _ => null,
            });
    await tester.tap(find.byType(DocumentMenu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Remove document?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.names, isNot(contains('remove_employee_document')));

    await tester.tap(find.byType(DocumentMenu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c.$1 == 'remove_employee_document').single.$2, {'p_record_id': '1'});
    await unmount(tester);
  });

  Map<String, dynamic> policies({required bool editor}) => {
        ..._list(const []),
        'company': [
          {..._doc('p1', 'Leave policy 2026', mine: false), 'can_edit': editor},
        ],
        'can_publish_policy': editor,
      };

  testWidgets('POL-UI-001 policy editors add, rename and remove company policies', (tester) async {
    await pumpScreen(tester, const DocumentsScreen(policiesOnly: true),
        session: testSession(roles: const ['admin'], permissions: const ['*']),
        handler: (fn, _) => fn == 'list_my_documents' ? policies(editor: true) : null);
    expect(find.text('Company policies'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add policy'), findsOneWidget);
    expect(find.text('Leave policy 2026'), findsOneWidget);
    expect(find.byType(DocumentMenu), findsOneWidget);
    expect(find.text('Your documents'), findsNothing, reason: 'policies page shows policies only');
    await unmount(tester);
  });

  testWidgets('POL-UI-002 employees only read company policies', (tester) async {
    await pumpScreen(tester, const DocumentsScreen(policiesOnly: true),
        session: testSession(),
        handler: (fn, _) => fn == 'list_my_documents' ? policies(editor: false) : null);
    expect(find.text('Leave policy 2026'), findsOneWidget);
    expect(find.text('Add policy'), findsNothing);
    expect(find.byType(DocumentMenu), findsNothing);
    await unmount(tester);
  });
}
