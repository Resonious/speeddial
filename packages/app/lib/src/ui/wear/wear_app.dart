import 'dart:async';

import 'package:flutter/material.dart';

import '../../scope.dart';
import '../../theme.dart';
import 'wear_shell.dart';

/// Compact SpeedDial application surface for the standalone Wear OS target.
///
/// It deliberately shares the full client's store graph and wire client, but
/// exposes only the workflows that make sense on a watch.
class WearSpeedDialApp extends StatefulWidget {
  const WearSpeedDialApp({super.key, required this.data});

  final AppData data;

  @override
  State<WearSpeedDialApp> createState() => _WearSpeedDialAppState();
}

class _WearSpeedDialAppState extends State<WearSpeedDialApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.data.reconnectAll();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.data.dispose();
    unawaited(widget.data.stopLocalDaemon());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      data: widget.data,
      child: MaterialApp(
        title: 'SpeedDial Wear',
        debugShowCheckedModeBanner: false,
        theme: _wearTheme(buildSpeedDialLightTheme()),
        darkTheme: _wearTheme(buildSpeedDialTheme()),
        themeMode: ThemeMode.system,
        home: const WearSpeedDialShell(),
      ),
    );
  }

  ThemeData _wearTheme(ThemeData base) => base.copyWith(
    scaffoldBackgroundColor: base.colorScheme.surface,
    appBarTheme: base.appBarTheme.copyWith(centerTitle: true),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      isDense: true,
      border: const OutlineInputBorder(),
    ),
  );
}
