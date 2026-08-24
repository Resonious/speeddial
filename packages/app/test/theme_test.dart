import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:speeddial_app/src/theme.dart';

void main() {
  testWidgets('dark theme uses a full-black scaffold background', (tester) async {
    final ThemeData dark = buildSpeedDialTheme();

    expect(dark.scaffoldBackgroundColor, const Color(0xFF000000),
        reason: 'scaffold background must be pure black in dark mode');

    // The colorScheme surface slot should match so any widget reading
    // scheme.surface also gets full black.
    expect(dark.colorScheme.surface, const Color(0xFF000000));
    expect(dark.colorScheme.surfaceContainerLowest, const Color(0xFF000000));
  });
}
