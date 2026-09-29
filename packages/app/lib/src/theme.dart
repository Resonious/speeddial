import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
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
    required this.terminalBackground,
    required this.terminalForeground,
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

  /// Terminal output well; dark in both themes.
  final Color terminalBackground;

  /// Text on [terminalBackground].
  final Color terminalForeground;

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
    Color? terminalBackground,
    Color? terminalForeground,
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
      terminalBackground: terminalBackground ?? this.terminalBackground,
      terminalForeground: terminalForeground ?? this.terminalForeground,
      mono: mono ?? this.mono,
    );
  }

  @override
  SpeedDialColors lerp(ThemeExtension<SpeedDialColors>? other, double t) {
    if (other is! SpeedDialColors) return this;
    return SpeedDialColors(
      running: Color.lerp(running, other.running, t)!,
      waitingPermission: Color.lerp(
        waitingPermission,
        other.waitingPermission,
        t,
      )!,
      error: Color.lerp(error, other.error, t)!,
      idle: Color.lerp(idle, other.idle, t)!,
      closed: Color.lerp(closed, other.closed, t)!,
      success: Color.lerp(success, other.success, t)!,
      attention: Color.lerp(attention, other.attention, t)!,
      purple: Color.lerp(purple, other.purple, t)!,
      diffRemove: Color.lerp(diffRemove, other.diffRemove, t)!,
      border: Color.lerp(border, other.border, t)!,
      codeBackground: Color.lerp(codeBackground, other.codeBackground, t)!,
      terminalBackground: Color.lerp(
        terminalBackground,
        other.terminalBackground,
        t,
      )!,
      terminalForeground: Color.lerp(
        terminalForeground,
        other.terminalForeground,
        t,
      )!,
      mono: TextStyle.lerp(mono, other.mono, t) ?? mono,
    );
  }
}

extension SpeedDialThemeX on ThemeData {
  SpeedDialColors get speedDialColors => extension<SpeedDialColors>()!;
}

extension SpeedDialContextX on BuildContext {
  SpeedDialColors get speedDialColors =>
      Theme.of(this).extension<SpeedDialColors>()!;
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

/// UI typeface, bundled in `fonts/` (see pubspec.yaml).
const String kSansFamily = 'IBM Plex Sans';

/// Code typeface, bundled in `fonts/` (see pubspec.yaml).
const String kMonoFamily = 'IBM Plex Mono';

const TextStyle _monoBase = TextStyle(
  fontFamily: kMonoFamily,
  fontFamilyFallback: <String>['monospace', 'Menlo', 'Consolas', 'Courier New'],
);

/// Radius for buttons, inputs, menus and other small controls.
const double _controlRadius = 6;

/// Radius for cards, dialogs and other containers.
const double _containerRadius = 10;

/// One complete color set for [_buildTheme]. Every surface role is spelled
/// out so nothing falls back to Material's seed-generated tonal palette.
class _Palette {
  const _Palette({
    required this.brightness,
    required this.canvas,
    required this.low,
    required this.panel,
    required this.card,
    required this.raised,
    required this.border,
    required this.outline,
    required this.fg,
    required this.fgMuted,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.onAccentSoft,
    required this.running,
    required this.waitingPermission,
    required this.error,
    required this.idle,
    required this.closed,
    required this.success,
    required this.attention,
    required this.purple,
    required this.diffRemove,
    required this.shadow,
  });

  final Brightness brightness;

  /// Chat canvas and scaffold.
  final Color canvas;

  /// Composer and tool-call detail wells; a step off [canvas].
  final Color low;

  /// Side rails, drawer, bottom sheets.
  final Color panel;

  /// Cards, dialogs, menus.
  final Color card;

  /// Inputs, selected rows, segmented-tab track.
  final Color raised;

  /// Hairline dividers and card borders.
  final Color border;

  /// Stronger border for outlined controls.
  final Color outline;

  final Color fg;
  final Color fgMuted;

  /// Signal orange: the one brand accent (user bubbles, focus, selection).
  final Color accent;
  final Color onAccent;

  /// Low-intensity accent fill (containers, text selection).
  final Color accentSoft;
  final Color onAccentSoft;

  final Color running;
  final Color waitingPermission;
  final Color error;
  final Color idle;
  final Color closed;
  final Color success;
  final Color attention;
  final Color purple;
  final Color diffRemove;
  final Color shadow;
}

/// Graphite: a pure-black canvas (OLED-friendly, see theme_test) framed by
/// warm graphite panels and cards, off-white ink, signal-orange accent.
const _Palette _dark = _Palette(
  brightness: Brightness.dark,
  canvas: Color(0xFF000000),
  low: Color(0xFF0C0C0B),
  panel: Color(0xFF151514),
  card: Color(0xFF1C1B19),
  raised: Color(0xFF282724),
  border: Color(0xFF2A2926),
  outline: Color(0xFF3F3D39),
  fg: Color(0xFFECE9E3),
  fgMuted: Color(0xFF9B978F),
  accent: Color(0xFFFF7A33),
  onAccent: Color(0xFF1B0D04),
  accentSoft: Color(0xFF3A2519),
  onAccentSoft: Color(0xFFFFC9A8),
  running: Color(0xFF6BB3FF),
  waitingPermission: Color(0xFFF2C14E),
  error: Color(0xFFF0555C),
  idle: Color(0xFF8E8A82),
  closed: Color(0xFF5C5953),
  success: Color(0xFF5CC98A),
  attention: Color(0xFFE39C3A),
  purple: Color(0xFFB59BFF),
  diffRemove: Color(0xFFFF6B6B),
  shadow: Color(0xFF000000),
);

/// Paper: warm off-white surfaces, graphite ink, the same orange accent
/// deepened for contrast.
const _Palette _light = _Palette(
  brightness: Brightness.light,
  canvas: Color(0xFFFBFAF7),
  low: Color(0xFFF6F4EF),
  panel: Color(0xFFF2F0EB),
  card: Color(0xFFFFFFFF),
  raised: Color(0xFFE9E6DF),
  border: Color(0xFFE2DED5),
  outline: Color(0xFFCCC7BC),
  fg: Color(0xFF1C1B19),
  fgMuted: Color(0xFF6A665E),
  accent: Color(0xFFD9531A),
  onAccent: Color(0xFFFFFFFF),
  accentSoft: Color(0xFFFBE3D5),
  onAccentSoft: Color(0xFF7A2A06),
  running: Color(0xFF1F6FD1),
  waitingPermission: Color(0xFF9E6A00),
  error: Color(0xFFC8323A),
  idle: Color(0xFF77736B),
  closed: Color(0xFFB3AEA4),
  success: Color(0xFF1E7F45),
  attention: Color(0xFFA56300),
  purple: Color(0xFF7550D6),
  diffRemove: Color(0xFFC8323A),
  shadow: Color(0xFF2B2418),
);

/// Dark "Graphite" theme: black canvas, warm graphite panels, hairline borders,
/// IBM Plex type, signal-orange accent, no ink ripples.
ThemeData buildSpeedDialTheme() => _buildTheme(_dark);

/// Light "Paper" counterpart; selected when the theme mode resolves to
/// light (see [SettingsStore]).
ThemeData buildSpeedDialLightTheme() => _buildTheme(_light);

ThemeData _buildTheme(_Palette p) {
  final bool dark = p.brightness == Brightness.dark;
  final ColorScheme scheme = ColorScheme(
    brightness: p.brightness,
    primary: p.accent,
    onPrimary: p.onAccent,
    primaryContainer: p.accentSoft,
    onPrimaryContainer: p.onAccentSoft,
    secondary: p.fgMuted,
    onSecondary: p.canvas,
    secondaryContainer: p.raised,
    onSecondaryContainer: p.fg,
    tertiary: p.purple,
    onTertiary: p.canvas,
    tertiaryContainer: Color.alphaBlend(
      p.purple.withValues(alpha: 0.16),
      p.card,
    ),
    onTertiaryContainer: p.fg,
    error: p.error,
    onError: Colors.white,
    errorContainer: Color.alphaBlend(p.error.withValues(alpha: 0.14), p.card),
    onErrorContainer: p.fg,
    surface: p.canvas,
    onSurface: p.fg,
    onSurfaceVariant: p.fgMuted,
    surfaceDim: p.low,
    surfaceBright: p.card,
    surfaceContainerLowest: p.canvas,
    surfaceContainerLow: p.low,
    surfaceContainer: p.panel,
    surfaceContainerHigh: p.card,
    surfaceContainerHighest: p.raised,
    surfaceTint: Colors.transparent,
    outline: p.outline,
    outlineVariant: p.border,
    shadow: p.shadow,
    scrim: p.shadow,
    inverseSurface: p.fg,
    onInverseSurface: p.canvas,
    inversePrimary: p.accentSoft,
  );

  final ThemeData base = ThemeData(
    colorScheme: scheme,
    fontFamily: kSansFamily,
    splashFactory: NoSplash.splashFactory,
    visualDensity: VisualDensity.compact,
  );
  final TextTheme text = _textTheme(base.textTheme, p);

  final Color hover = p.fg.withValues(alpha: dark ? 0.06 : 0.05);
  final Color pressed = p.fg.withValues(alpha: dark ? 0.10 : 0.08);
  final WidgetStateProperty<Color?> overlay =
      WidgetStateProperty.resolveWith<Color?>((Set<WidgetState> states) {
        if (states.contains(WidgetState.pressed)) return pressed;
        if (states.contains(WidgetState.hovered)) return hover;
        if (states.contains(WidgetState.focused)) return hover;
        return null;
      });
  const RoundedRectangleBorder controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(_controlRadius)),
  );
  final RoundedRectangleBorder containerShape = RoundedRectangleBorder(
    borderRadius: const BorderRadius.all(Radius.circular(_containerRadius)),
    side: BorderSide(color: p.border),
  );
  final TextStyle buttonText = TextStyle(
    fontFamily: kSansFamily,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );
  final OutlineInputBorder inputBorder = OutlineInputBorder(
    borderRadius: const BorderRadius.all(Radius.circular(_controlRadius + 2)),
    borderSide: BorderSide(color: p.border),
  );

  return base.copyWith(
    scaffoldBackgroundColor: p.canvas,
    canvasColor: p.canvas,
    hoverColor: hover,
    highlightColor: pressed,
    focusColor: hover,
    splashColor: Colors.transparent,
    textTheme: text,
    primaryTextTheme: text,
    iconTheme: IconThemeData(color: p.fgMuted, size: 20),
    dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: _FadeRisePageTransitionsBuilder(),
        // Keeps the edge swipe-back gesture.
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: _FadeRisePageTransitionsBuilder(),
        TargetPlatform.macOS: _FadeRisePageTransitionsBuilder(),
        TargetPlatform.windows: _FadeRisePageTransitionsBuilder(),
        TargetPlatform.fuchsia: _FadeRisePageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarThemeData(
      backgroundColor: p.canvas,
      foregroundColor: p.fg,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleSpacing: 4,
      shape: Border(bottom: BorderSide(color: p.border)),
      titleTextStyle: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      iconTheme: IconThemeData(color: p.fgMuted, size: 20),
      actionsIconTheme: IconThemeData(color: p.fgMuted, size: 20),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: p.card,
      surfaceTintColor: Colors.transparent,
      shape: containerShape,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.card,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: p.shadow.withValues(alpha: dark ? 0.6 : 0.18),
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: p.border),
      ),
      titleTextStyle: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      contentTextStyle: text.bodyMedium?.copyWith(color: p.fgMuted),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: p.panel,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(),
      endShape: const RoundedRectangleBorder(),
      scrimColor: p.shadow.withValues(alpha: 0.45),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.panel,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: p.shadow.withValues(alpha: 0.45),
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
        side: BorderSide(color: p.border),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.fgMuted,
      textColor: p.fg,
      selectedColor: p.fg,
      selectedTileColor: p.raised,
      titleTextStyle: text.bodyMedium,
      subtitleTextStyle: text.bodySmall?.copyWith(color: p.fgMuted),
    ),
    expansionTileTheme: ExpansionTileThemeData(
      iconColor: p.fgMuted,
      collapsedIconColor: p.fgMuted,
      textColor: p.fg,
      collapsedTextColor: p.fg,
      shape: const Border(),
      collapsedShape: const Border(),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: p.card,
      hoverColor: Colors.transparent,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      hintStyle: text.bodyMedium?.copyWith(color: p.fgMuted),
      labelStyle: text.bodyMedium?.copyWith(color: p.fgMuted),
      floatingLabelStyle: text.bodySmall?.copyWith(color: p.accent),
      border: inputBorder,
      enabledBorder: inputBorder,
      disabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: p.accent, width: 1.5),
      ),
      errorBorder: inputBorder.copyWith(borderSide: BorderSide(color: p.error)),
      focusedErrorBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: p.error, width: 1.5),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: p.fg,
      unselectedLabelColor: p.fgMuted,
      labelStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      unselectedLabelStyle: text.labelLarge?.copyWith(
        fontWeight: FontWeight.w500,
      ),
      dividerColor: Colors.transparent,
      dividerHeight: 0,
      indicatorSize: TabBarIndicatorSize.tab,
      indicator: BoxDecoration(
        color: dark ? p.outline : p.card,
        borderRadius: const BorderRadius.all(Radius.circular(_controlRadius)),
        boxShadow: dark
            ? null
            : <BoxShadow>[
                BoxShadow(
                  color: p.shadow.withValues(alpha: 0.10),
                  blurRadius: 2,
                  offset: const Offset(0, 1),
                ),
              ],
      ),
      overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      splashFactory: NoSplash.splashFactory,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        disabledBackgroundColor: p.raised,
        disabledForegroundColor: p.fgMuted,
        elevation: 0,
        shape: controlShape,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        textStyle: buttonText,
        splashFactory: NoSplash.splashFactory,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: p.card,
        foregroundColor: p.fg,
        elevation: 0,
        shape: controlShape,
        side: BorderSide(color: p.outline),
        minimumSize: const Size(0, 34),
        textStyle: buttonText,
        splashFactory: NoSplash.splashFactory,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.fg,
        side: BorderSide(color: p.outline),
        shape: controlShape,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        textStyle: buttonText,
        splashFactory: NoSplash.splashFactory,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        shape: controlShape,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        textStyle: buttonText,
        splashFactory: NoSplash.splashFactory,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll<OutlinedBorder>(controlShape),
        overlayColor: overlay,
        splashFactory: NoSplash.splashFactory,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.card,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: p.shadow.withValues(alpha: dark ? 0.6 : 0.2),
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        side: BorderSide(color: p.border),
      ),
      textStyle: text.bodyMedium,
      labelTextStyle: WidgetStatePropertyAll<TextStyle?>(text.bodyMedium),
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll<Color>(p.card),
        surfaceTintColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
        elevation: const WidgetStatePropertyAll<double>(8),
        shadowColor: WidgetStatePropertyAll<Color>(
          p.shadow.withValues(alpha: dark ? 0.6 : 0.2),
        ),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            side: BorderSide(color: p.border),
          ),
        ),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(textStyle: text.bodyMedium),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.fg,
        borderRadius: const BorderRadius.all(Radius.circular(4)),
      ),
      textStyle: text.bodySmall?.copyWith(color: p.canvas),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      waitDuration: const Duration(milliseconds: 400),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.fg,
      contentTextStyle: text.bodyMedium?.copyWith(color: p.canvas),
      actionTextColor: dark ? _light.accent : _dark.accent,
      elevation: 4,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      behavior: SnackBarBehavior.floating,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.card,
      selectedColor: p.accentSoft,
      side: BorderSide(color: p.border),
      shape: controlShape,
      labelStyle: text.bodySmall,
      showCheckmark: false,
    ),
    checkboxTheme: CheckboxThemeData(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(4)),
      ),
      side: BorderSide(color: p.outline, width: 1.5),
      fillColor: WidgetStateProperty.resolveWith<Color?>((
        Set<WidgetState> states,
      ) {
        if (states.contains(WidgetState.selected)) return p.accent;
        return Colors.transparent;
      }),
      checkColor: WidgetStatePropertyAll<Color>(p.onAccent),
      overlayColor: overlay,
      splashRadius: 0,
    ),
    switchTheme: SwitchThemeData(
      // A non-null icon keeps the thumb one size in both states, which reads
      // as a plain toggle rather than Material 3's growing thumb.
      thumbIcon: const WidgetStatePropertyAll<Icon>(Icon(null)),
      thumbColor: WidgetStateProperty.resolveWith<Color>((
        Set<WidgetState> states,
      ) {
        if (states.contains(WidgetState.selected)) return p.onAccent;
        return dark ? p.fgMuted : p.card;
      }),
      trackColor: WidgetStateProperty.resolveWith<Color>((
        Set<WidgetState> states,
      ) {
        if (states.contains(WidgetState.selected)) return p.accent;
        return p.raised;
      }),
      trackOutlineColor: WidgetStatePropertyAll<Color>(p.border),
      trackOutlineWidth: const WidgetStatePropertyAll<double>(1),
      overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith<Color?>((
        Set<WidgetState> states,
      ) {
        if (states.contains(WidgetState.selected)) return p.accent;
        return p.outline;
      }),
      overlayColor: overlay,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accent,
      linearTrackColor: p.raised,
      circularTrackColor: Colors.transparent,
      linearMinHeight: 2,
      strokeWidth: 2,
      strokeCap: StrokeCap.round,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll<double>(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStateProperty.resolveWith<Color>((
        Set<WidgetState> states,
      ) {
        final bool active =
            states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.dragged);
        return p.fg.withValues(alpha: active ? 0.32 : 0.18);
      }),
      crossAxisMargin: 2,
      mainAxisMargin: 2,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accent,
      selectionColor: p.accent.withValues(alpha: dark ? 0.32 : 0.24),
      selectionHandleColor: p.accent,
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: p.accent,
      textColor: p.onAccent,
    ),
    extensions: <ThemeExtension<dynamic>>[
      SpeedDialColors(
        running: p.running,
        waitingPermission: p.waitingPermission,
        error: p.error,
        idle: p.idle,
        closed: p.closed,
        success: p.success,
        attention: p.attention,
        purple: p.purple,
        diffRemove: p.diffRemove,
        border: p.border,
        codeBackground: dark ? const Color(0xFF0E0E0D) : p.panel,
        terminalBackground: const Color(0xFF0E0E0D),
        terminalForeground: const Color(0xFFE4E0D8),
        mono: _monoBase.copyWith(fontSize: 12, height: 1.5, color: p.fg),
      ),
    ],
  );
}

/// Material 2021 sizes with Plex-friendly tracking: no positive letter
/// spacing on body/labels (it reads as Roboto-on-Android), tighter display
/// sizes, and small tracked section labels.
TextTheme _textTheme(TextTheme base, _Palette p) {
  final TextTheme t = base.apply(
    fontFamily: kSansFamily,
    bodyColor: p.fg,
    displayColor: p.fg,
  );
  return t.copyWith(
    headlineSmall: t.headlineSmall?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
    ),
    titleLarge: t.titleLarge?.copyWith(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.1,
    ),
    titleMedium: t.titleMedium?.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    titleSmall: t.titleSmall?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    bodyLarge: t.bodyLarge?.copyWith(letterSpacing: 0),
    bodyMedium: t.bodyMedium?.copyWith(fontSize: 13.5, letterSpacing: 0),
    bodySmall: t.bodySmall?.copyWith(letterSpacing: 0),
    labelLarge: t.labelLarge?.copyWith(fontSize: 13, letterSpacing: 0),
    labelMedium: t.labelMedium?.copyWith(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.6,
    ),
    labelSmall: t.labelSmall?.copyWith(letterSpacing: 0.2),
  );
}

/// Short fade with a slight upward drift, in place of Android's zoom and
/// the desktop fade; pushed settings pages feel like panels, not activities.
class _FadeRisePageTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeRisePageTransitionsBuilder();

  static final Animatable<Offset> _rise = Tween<Offset>(
    begin: const Offset(0, 0.015),
    end: Offset.zero,
  ).chain(CurveTween(curve: Curves.easeOutCubic));

  static final Animatable<double> _fade = CurveTween(curve: Curves.easeOut);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: animation.drive(_fade),
      child: SlideTransition(position: animation.drive(_rise), child: child),
    );
  }
}
