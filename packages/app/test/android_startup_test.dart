import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_app/main.dart' as app;

void main() {
  testWidgets('Android draws the app while watch publication is pending', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const MethodChannel shares = MethodChannel('sh.speeddial/share');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      shares,
      (_) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        shares,
        null,
      ),
    );
    const MethodChannel channel = MethodChannel('sh.speeddial/companion');
    final Completer<void> publication = Completer<void>();
    bool requested = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      MethodCall call,
    ) async {
      if (call.method == 'publishEndpoints') {
        requested = true;
        await publication.future;
      }
      return null;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    // Do not await main: the regression leaves it waiting for watch delivery.
    bool started = false;
    unawaited(app.main(<String>[]).then((_) => started = true));
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    try {
      expect(requested, isTrue);
      expect(publication.isCompleted, isFalse);
      expect(started, isTrue);
      expect(find.byType(app.SpeedDialApp), findsOneWidget);
      expect(find.byType(MaterialApp), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      publication.complete();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
