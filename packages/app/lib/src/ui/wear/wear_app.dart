import 'dart:async';

import 'package:flutter/material.dart';

import '../../companion/companion_endpoint_sync.dart';
import '../../companion/phone_proxy_channel.dart';
import '../../scope.dart';
import '../../theme.dart';
import 'wear_shell.dart';

/// Compact SpeedDial application surface for the standalone Wear OS target.
///
/// It deliberately shares the full client's store graph and wire client, but
/// exposes only the workflows that make sense on a watch.
class WearSpeedDialApp extends StatefulWidget {
  const WearSpeedDialApp({
    super.key,
    required this.data,
    this.companionSync,
    this.phoneProxy,
  });

  final AppData data;
  final CompanionEndpointSync? companionSync;
  final PhoneProxyChannelFactory? phoneProxy;

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
      final CompanionEndpointSync? sync = widget.companionSync;
      if (sync != null) {
        unawaited(sync.refreshWatch(widget.data.connections));
      }
      widget.data.reconnectAll();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.companionSync?.dispose();
    unawaited(widget.phoneProxy?.dispose());
    widget.data.dispose();
    unawaited(widget.data.stopLocalDaemon());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      data: widget.data,
      child: ListenableBuilder(
        listenable: widget.data.settings,
        builder: (BuildContext context, Widget? _) {
          return MaterialApp(
            title: 'SpeedDial Wear',
            debugShowCheckedModeBanner: false,
            theme: _wearTheme(buildSpeedDialLightTheme()),
            darkTheme: _wearTheme(buildSpeedDialTheme()),
            themeMode: widget.data.settings.themeMode,
            home: const WearSpeedDialShell(),
          );
        },
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
