import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Something the user pressed in the native title bar.
enum NativeTitleBarAction { toggleLeft, toggleRight, cycleTheme }

/// Everything the native title bar shows. Equality lets [NativeTitleBar.show]
/// skip redundant platform-channel calls when the shell rebuilds.
@immutable
class NativeTitleBarState {
  const NativeTitleBarState({
    required this.title,
    required this.status,
    required this.statusColor,
    required this.leftOpen,
    required this.rightOpen,
    required this.themeMode,
    required this.dark,
  });

  final String title;
  final String status;
  final Color statusColor;
  final bool leftOpen;
  final bool rightOpen;
  final ThemeMode themeMode;

  /// The brightness the app actually resolved to; the runner asks GTK for its
  /// matching dark/light variant so the header bar sits with the app.
  final bool dark;

  Map<String, Object?> toMap() => <String, Object?>{
    'title': title,
    'status': status,
    'statusColor': statusColor.toARGB32(),
    'leftOpen': leftOpen,
    'rightOpen': rightOpen,
    'themeMode': themeMode.name,
    'dark': dark,
  };

  @override
  bool operator ==(Object other) =>
      other is NativeTitleBarState &&
      other.title == title &&
      other.status == status &&
      other.statusColor == statusColor &&
      other.leftOpen == leftOpen &&
      other.rightOpen == rightOpen &&
      other.themeMode == themeMode &&
      other.dark == dark;

  @override
  int get hashCode => Object.hash(
    title,
    status,
    statusColor,
    leftOpen,
    rightOpen,
    themeMode,
    dark,
  );
}

/// The Linux runner's GTK header bar (`linux/runner/native_title_bar.cc`),
/// which replaces the Flutter top bar when the window has one. Created by
/// [attach]; null everywhere else (other platforms, X11 window managers that
/// get a plain title bar, tests).
class NativeTitleBar {
  NativeTitleBar._(this._channel) {
    _channel.setMethodCallHandler(_handle);
  }

  static const MethodChannel defaultChannel = MethodChannel(
    'speeddial/title_bar',
  );

  /// Asks the runner to reveal its header-bar controls. Returns null when
  /// there is no native header bar to drive.
  static Future<NativeTitleBar?> attach({
    MethodChannel channel = defaultChannel,
  }) async {
    final bool? attached;
    try {
      attached = await channel.invokeMethod<bool>('attach');
    } on MissingPluginException {
      return null;
    }
    return attached == true ? NativeTitleBar._(channel) : null;
  }

  final MethodChannel _channel;
  NativeTitleBarState? _shown;

  /// Receives button presses; the shell sets this while it is mounted.
  ValueChanged<NativeTitleBarAction>? onAction;

  /// Pushes [state] to the header bar if it differs from what is showing.
  void show(NativeTitleBarState state) {
    if (state == _shown) return;
    _shown = state;
    unawaited(
      _channel.invokeMethod<void>('update', state.toMap()).catchError((
        Object error,
      ) {
        // Forget what we sent so the next rebuild retries.
        _shown = null;
        debugPrint('Native title bar update failed: $error');
      }),
    );
  }

  Future<Object?> _handle(MethodCall call) async {
    final NativeTitleBarAction? action = switch (call.method) {
      'toggleLeft' => NativeTitleBarAction.toggleLeft,
      'toggleRight' => NativeTitleBarAction.toggleRight,
      'cycleTheme' => NativeTitleBarAction.cycleTheme,
      _ => null,
    };
    if (action == null) {
      throw MissingPluginException('Unknown title bar call ${call.method}');
    }
    onAction?.call(action);
    return null;
  }
}
