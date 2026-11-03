import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/left/branch_picker.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

const List<Branch> _branches = <Branch>[
  Branch(name: 'main', isCurrent: true),
  Branch(name: 'feature/branch-search', isCurrent: false),
  Branch(name: 'fix/keyboard', isCurrent: false),
];
final Finder _query = find.byKey(const Key('branch-picker-query'));
final Finder _picker = find.byType(BranchPicker);

Future<void> _pumpPicker(
  WidgetTester tester, {
  List<Branch> branches = _branches,
  ValueChanged<String>? onChanged,
  bool enabled = true,
  bool dark = true,
  bool reducedMotion = false,
  double textScale = 1,
}) async {
  String selected = 'main';
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? buildSpeedDialTheme() : buildSpeedDialLightTheme(),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reducedMotion,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) => Padding(
            padding: const EdgeInsets.all(20),
            child: BranchPicker(
              branches: branches,
              value: selected,
              onChanged: !enabled
                  ? null
                  : (String value) {
                      setState(() => selected = value);
                      onChanged?.call(value);
                    },
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(_picker);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'search starts empty on every open and selection stays separate',
    (WidgetTester tester) async {
      final List<String> selections = <String>[];
      await _pumpPicker(tester, onChanged: selections.add);
      expect(find.text('main'), findsOneWidget);

      await _open(tester);
      final EditableText search = tester.widget<EditableText>(
        find.descendant(of: _query, matching: find.byType(EditableText)),
      );
      expect(search.controller.text, isEmpty);
      expect(search.focusNode.hasFocus, isTrue);
      expect(find.byIcon(Icons.check), findsOneWidget);
      final Size searchSize = tester.getSize(_query);

      await tester.enterText(_query, '  BRANCH-SEARCH  ');
      await tester.pump();
      expect(tester.getSize(_query), searchSize);
      expect(find.byType(ListTile), findsOneWidget);
      expect(selections, isEmpty);
      await tester.tap(find.text('feature/branch-search'));
      await tester.pumpAndSettle();
      expect(selections, <String>['feature/branch-search']);
      expect(find.text('feature/branch-search'), findsOneWidget);

      await _open(tester);
      expect(tester.widget<TextField>(_query).controller!.text, isEmpty);
      expect(find.byType(ListTile), findsNWidgets(3));
      await tester.enterText(_query, 'keyboard');
      await tester.pump();
      await tester.tap(find.byTooltip('Close branch picker'));
      await tester.pumpAndSettle();
      expect(selections, <String>['feature/branch-search']);
      expect(find.text('feature/branch-search'), findsOneWidget);
    },
  );

  testWidgets(
    'no matches cannot be submitted and clear restores all branches',
    (WidgetTester tester) async {
      final List<String> selections = <String>[];
      await _pumpPicker(tester, onChanged: selections.add);
      await _open(tester);
      await tester.enterText(_query, 'does-not-exist');
      await tester.pump();
      expect(find.text('No matching branches'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(find.byType(Dialog), findsOneWidget);
      expect(selections, isEmpty);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();
      expect(tester.widget<TextField>(_query).controller!.text, isEmpty);
      expect(find.byType(ListTile), findsNWidgets(3));
      expect(find.text('No matching branches'), findsNothing);
    },
  );

  testWidgets('arrow keys choose a branch, Escape cancels', (
    WidgetTester tester,
  ) async {
    final List<String> selections = <String>[];
    await _pumpPicker(tester, onChanged: selections.add);
    await _open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(selections, <String>['feature/branch-search']);

    await _open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(selections, <String>['feature/branch-search']);
  });

  testWidgets('disabled picker cannot open', (WidgetTester tester) async {
    await _pumpPicker(tester, enabled: false);
    await _open(tester);
    expect(find.byType(Dialog), findsNothing);
  });

  for (final bool dark in <bool>[true, false]) {
    testWidgets('search stays above a scrolling list with the mobile keyboard '
        '(${dark ? 'dark' : 'light'}, reduced motion)', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      final List<Branch> branches = <Branch>[
        ..._branches,
        for (int i = 0; i < 100; i++)
          Branch(name: 'feature/long-branch-name-$i', isCurrent: false),
      ];
      await _pumpPicker(
        tester,
        branches: branches,
        dark: dark,
        reducedMotion: true,
        textScale: dark ? 1 : 1.6,
      );
      await _open(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      final Offset searchPosition = tester.getTopLeft(_query);
      expect(tester.getBottomRight(_query).dy, lessThan(844 - 320));
      final Finder list = find.byType(ListView);
      await tester.drag(list, const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(_query), searchPosition);
      expect(tester.takeException(), isNull);
      expect(tester.hasRunningAnimations, isFalse);
      await tester.enterText(_query, 'name-99');
      await tester.pump();
      expect(find.text('feature/long-branch-name-99'), findsOneWidget);
      await tester.tap(find.text('feature/long-branch-name-99'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });
  }
}
