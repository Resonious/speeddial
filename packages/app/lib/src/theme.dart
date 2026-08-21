import 'package:flutter/material.dart';

import 'scope.dart';

/// SpeedDial-specific theming data: daemon/session status colors, hairline
/// borders, code backgrounds and the monospace text style. Surfaced through
/// `ThemeData.extensions` and read via the `speedDialColors` getters below,
/// so widget code never hard-codes palette values.
@immutable
class SpeedDialColors extends ThemeExtension<SpeedDialColors> {
  const SpeedDialColors({
    required this.running,
    required this.waitingPermission,
    required this.error,
    required this.idle,
    required this.closed,
    required this.success,
    required this.attention,
    required this.purple,
    required this.diffRemove,
    required this.border,
    required this.codeBackground,
    required this.mono,
  });

  /// Blue — running sessions, connected daemons.
  final Color running;

  /// Amber — waiting-permission prompts.
  final Color waitingPermission;

  /// Red — errors, failed connections.
  final Color error;

  /// Grey — idle sessions, disconnected daemons.
  final Color idle;

  /// Dimmed grey — closed/archived sessions.
  final Color closed;

  /// Green — completed/success states, diff additions.
  final Color success;

  /// Deep amber — 'move' tool-call accents.
  final Color attention;

  /// Purple — 'search' tool-call accents.
  final Color purple;

  /// Red for diff deletions; brighter than [error] in dark mode where the
  /// button red is too dim for text.
  final Color diffRemove;

  /// Subtle hairline border for rails, dividers, cards, inputs.
  final Color border;

  /// Background for inline code and code blocks.
  final Color codeBackground;

  /// Monospace text style for code, paths and IDs.
  final TextStyle mono;

  @override
  SpeedDialColors copyWith({
    Color? running,
    Color? waitingPermission,
    Color? error,
    Color? idle,
    Color? closed,
    Color? success,
    Color? attention,
    Color? purple,
    Color? diffRemove,
    Color? border,
    Color? codeBackground,
    TextStyle? mono,
  }) {
    return SpeedDialColors(
      running: running ?? this.running,
      waitingPermission: waitingPermission ?? this.waitingPermission,
      error: error ?? this.error,
      idle: idle ?? this.idle,
      closed: closed ?? this.closed,
      success: success ?? this.success,
      attention: attention ?? this.attention,
      purple: purple ?? this.purple,
      diffRemove: diffRemove ?? this.diffRemove,
      border: border ?? this.border,
      codeBackground: codeBackground ?? this.codeBackground,
      mono: mono ?? this.mono,
    );
  }

  @override
  SpeedDialColors lerp(ThemeExtension<SpeedDialColors>? other, double t) {
    if (other is! SpeedDialColors) return this;
    return SpeedDialColors(
      running: Color.lerp(running, other.running, t)!,
      waitingPermission: Color.lerp(waitingPermission, other.waitingPermission, t)!,
      error: Color.lerp(error, other.error, t)!,
      idle: Color.lerp(idle, other.idle, t)!,
      closed: Color.lerp(closed, other.closed, t)!,
      success: Color.lerp(success, other.success, t)!,
      attention: Color.lerp(attention, other.attention, t)!,
      purple: Color.lerp(purple, other.purple, t)!,
      diffRemove: Color.lerp(diffRemove, other.diffRemove, t)!,
      border: Color.lerp(border, other.border, t)!,
      codeBackground: Color.lerp(codeBackground, other.codeBackground, t)!,
      mono: TextStyle.lerp(mono, other.mono, t) ?? mono,
    );
  }
}

extension SpeedDialThemeX on ThemeData {
  SpeedDialColors get speedDialColors => extension<SpeedDialColors>()!;
}

extension SpeedDialContextX on BuildContext {
  SpeedDialColors get speedDialColors => Theme.of(this).extension<SpeedDialColors>()!;
}

/// Maps a daemon connection state to its palette color.
Color connectionStatusColor(BuildContext context, ConnectionStatus status) {
  switch (status) {
    case ConnectionStatus.connecting:
    case ConnectionStatus.connected:
      return context.speedDialColors.running;
    case ConnectionStatus.reconnecting:
      return context.speedDialColors.waitingPermission;
    case ConnectionStatus.failed:
      return context.speedDialColors.error;
    case ConnectionStatus.disconnected:
      return context.speedDialColors.idle;
  }
}

const TextStyle _monoBase = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['Roboto Mono', 'Menlo', 'Consolas', 'Courier New'],
);

/// Dark-first Material 3 theme: near-black GitHub-style surfaces, subtle
/// hairline borders, round-8 cards, compact density, blue accent.
ThemeData buildSpeedDialTheme() {
  const Color surface = Color(0xFF0D1117);
  const Color panel = Color(0xFF161B22);
  const Color card = Color(0xFF21262D);
  const Color raised = Color(0xFF2D333B);
  const Color border = Color(0xFF30363D);
  const Color fg = Color(0xFFE6EDF3);
  const Color fgMuted = Color(0xFF8B949E);

  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF58A6FF),
    brightness: Brightness.dark,
    surface: surface,
    onSurface: fg,
    onSurfaceVariant: fgMuted,
    surfaceContainerLowest: const Color(0xFF0A0D12),
    surfaceContainerLow: surface,
    surfaceContainer: panel,
    surfaceContainerHigh: card,
    surfaceContainerHighest: raised,
    surfaceDim: surface,
    surfaceBright: panel,
    outline: border,
    outlineVariant: border,
    error: const Color(0xFFE5534B),
    onError: Colors.white,
  );

  const OutlineInputBorder inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(8)),
    borderSide: BorderSide(color: border),
  );

  final ThemeData base = ThemeData(colorScheme: scheme);

  return base.copyWith(
    scaffoldBackgroundColor: surface,
    visualDensity: VisualDensity.compact,
    textTheme: base.textTheme.apply(bodyColor: fg, displayColor: fg),
    dividerTheme: const DividerThemeData(color: border, thickness: 1, space: 1),
    appBarTheme: const AppBarThemeData(
      backgroundColor: surface,
      foregroundColor: fg,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    cardTheme: const CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        side: BorderSide(color: border),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    drawerTheme: const DrawerThemeData(backgroundColor: panel),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: fgMuted,
      textColor: fg,
      selectedColor: scheme.primary,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: raised,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: fg,
      unselectedLabelColor: fgMuted,
      dividerColor: border,
      indicatorColor: scheme.primary,
    ),
    extensions: <ThemeExtension<dynamic>>[
      SpeedDialColors(
        running: const Color(0xFF58A6FF),
        waitingPermission: const Color(0xFFE3B341),
        error: const Color(0xFFE5534B),
        idle: const Color(0xFF8B949E),
        closed: const Color(0xFF59636E),
        success: const Color(0xFF3FB950),
        attention: const Color(0xFFD29922),
        purple: const Color(0xFFA371F7),
        diffRemove: const Color(0xFFF85149),
        border: border,
        codeBackground: panel,
        mono: _monoBase.copyWith(fontSize: 12, height: 1.5, color: fg),
      ),
    ],
  );
}

/// Matching light theme (GitHub-light palette); selected when the theme
/// mode resolves to light (see [SettingsStore]).
ThemeData buildSpeedDialLightTheme() {
  const Color surface = Color(0xFFF6F8FA);
  const Color panel = Color(0xFFFFFFFF);
  const Color card = Color(0xFFFFFFFF);
  const Color raised = Color(0xFFE9EDF1);
  const Color border = Color(0xFFD0D7DE);
  const Color fg = Color(0xFF1F2328);
  const Color fgMuted = Color(0xFF656D76);

  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF0969DA),
    surface: surface,
    onSurface: fg,
    onSurfaceVariant: fgMuted,
    surfaceContainerLowest: const Color(0xFFFFFFFF),
    surfaceContainerLow: card,
    surfaceContainer: panel,
    surfaceContainerHigh: card,
    surfaceContainerHighest: raised,
    surfaceDim: const Color(0xFFDCE1E6),
    surfaceBright: const Color(0xFFFFFFFF),
    outline: border,
    outlineVariant: border,
    error: const Color(0xFFCF222E),
    onError: Colors.white,
  );

  final OutlineInputBorder inputBorder = OutlineInputBorder(
    borderRadius: const BorderRadius.all(Radius.circular(8)),
    borderSide: const BorderSide(color: border),
  );

  final ThemeData base = ThemeData(
    brightness: Brightness.light,
    colorScheme: scheme,
  );

  return base.copyWith(
    scaffoldBackgroundColor: surface,
    visualDensity: VisualDensity.compact,
    textTheme: base.textTheme.apply(bodyColor: fg, displayColor: fg),
    dividerTheme: const DividerThemeData(color: border, thickness: 1, space: 1),
    appBarTheme: const AppBarThemeData(
      backgroundColor: surface,
      foregroundColor: fg,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    cardTheme: const CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        side: BorderSide(color: border),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    drawerTheme: const DrawerThemeData(backgroundColor: panel),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: fgMuted,
      textColor: fg,
      selectedColor: scheme.primary,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: raised,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: fg,
      unselectedLabelColor: fgMuted,
      dividerColor: border,
      indicatorColor: scheme.primary,
    ),
    extensions: <ThemeExtension<dynamic>>[
      SpeedDialColors(
        running: const Color(0xFF0969DA),
        waitingPermission: const Color(0xFF9A6700),
        error: const Color(0xFFCF222E),
        idle: const Color(0xFF6E7781),
        closed: const Color(0xFFAEB6BF),
        success: const Color(0xFF1A7F37),
        attention: const Color(0xFF9A6700),
        purple: const Color(0xFF8250DF),
        diffRemove: const Color(0xFFCF222E),
        border: border,
        codeBackground: surface,
        mono: _monoBase.copyWith(fontSize: 12, height: 1.5, color: fg),
      ),
    ],
  );
}
