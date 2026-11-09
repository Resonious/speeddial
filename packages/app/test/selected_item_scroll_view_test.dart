import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/ui/left/selected_item_scroll_view.dart';

void main() {
  testWidgets('tracks lazy selections, clipping, resizing and removal', (
    WidgetTester tester,
  ) async {
    Future<void> build({int selected = 50, double height = 200}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                height: height,
                child: SelectedItemScrollView(
                  selectedIndex: selected,
                  itemLabel: 'session',
                  itemCount: 100,
                  itemBuilder:
                      (BuildContext context, int index, bool selected) =>
                          RailSelectionTarget(
                            selected: selected,
                            child: SizedBox(
                              height: 50,
                              child: Text('Row $index'),
                            ),
                          ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await build();
    expect(find.text('Row 50'), findsNothing);
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    final ScrollPosition position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    position.jumpTo(2500);
    await tester.pumpAndSettle();
    expect(find.text('Row 50'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_downward), findsNothing);
    expect(find.byIcon(Icons.arrow_upward), findsNothing);
    position.jumpTo(2520);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    position.jumpTo(4000);
    await tester.pumpAndSettle();
    expect(find.text('Row 50'), findsNothing);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    await build(selected: 83);
    expect(find.byIcon(Icons.arrow_upward), findsNothing);
    await build(selected: 83, height: 100);
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    await build(selected: -1);
    expect(find.byIcon(Icons.arrow_downward), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('tracks selected child inside a tall project', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 200,
            child: SelectedItemScrollView(
              selectedIndex: 0,
              itemLabel: 'session',
              itemCount: 1,
              itemBuilder: (BuildContext context, int index, bool selected) =>
                  Column(
                    children: <Widget>[
                      const SizedBox(height: 500),
                      RailSelectionTarget(
                        selected: selected,
                        child: const SizedBox(
                          height: 50,
                          child: Text('Selected session'),
                        ),
                      ),
                      const SizedBox(height: 500),
                    ],
                  ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    final ScrollPosition position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_downward), findsNothing);
    position.jumpTo(600);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_upward), findsNothing);
  });
  testWidgets('changing selection preserves row state', (
    WidgetTester tester,
  ) async {
    Future<void> build(int selectedIndex) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SelectedItemScrollView(
              selectedIndex: selectedIndex,
              itemLabel: 'session',
              itemCount: 3,
              itemBuilder: (BuildContext context, int index, bool selected) =>
                  RailSelectionTarget(
                    selected: selected,
                    child: TextField(key: ValueKey<int>(index)),
                  ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await build(0);
    final State<StatefulWidget> first = tester.state(
      find.byKey(const ValueKey<int>(0)),
    );
    final State<StatefulWidget> second = tester.state(
      find.byKey(const ValueKey<int>(1)),
    );
    await build(1);
    expect(tester.state(find.byKey(const ValueKey<int>(0))), same(first));
    expect(tester.state(find.byKey(const ValueKey<int>(1))), same(second));
    expect(tester.hasRunningAnimations, isFalse);
  });
  for (final bool reducedMotion in <bool>[false, true]) {
    testWidgets(
      'arrow reveals distant variable-height rows (reduced: $reducedMotion)',
      (WidgetTester tester) async {
        int builds = 0;
        Future<void> build(int selectedIndex) async {
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(disableAnimations: reducedMotion),
                child: Scaffold(
                  body: SizedBox(
                    width: 300,
                    height: 240,
                    child: SelectedItemScrollView(
                      selectedIndex: selectedIndex,
                      itemLabel: 'session',
                      itemCount: 5000,
                      itemBuilder:
                          (BuildContext context, int index, bool selected) {
                            builds++;
                            return RailSelectionTarget(
                              selected: selected,
                              child: SizedBox(
                                height: index % 97 == 0
                                    ? 800
                                    : 40 + (index % 11) * 10,
                                child: Text('Row $index'),
                              ),
                            );
                          },
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        Future<void> reveal(int selectedIndex, IconData arrow) async {
          expect(find.text('Row $selectedIndex'), findsNothing);
          await tester.tap(find.byIcon(arrow));
          await tester.pumpAndSettle();
          final Rect target = tester.getRect(find.text('Row $selectedIndex'));
          final Rect viewport = tester.getRect(
            find.byType(SelectedItemScrollView),
          );
          expect(target.top, greaterThanOrEqualTo(viewport.top));
          expect(target.bottom, lessThanOrEqualTo(viewport.bottom));
          expect(find.byIcon(Icons.arrow_upward), findsNothing);
          expect(find.byIcon(Icons.arrow_downward), findsNothing);
          expect(tester.hasRunningAnimations, isFalse);
        }

        await build(4990);
        await reveal(4990, Icons.arrow_downward);
        await build(3);
        await reveal(3, Icons.arrow_upward);
        expect(builds, lessThan(500));
      },
    );
  }
}
