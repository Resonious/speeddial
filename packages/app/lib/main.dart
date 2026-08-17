import 'dart:async';

import 'package:flutter/material.dart';

import 'src/scope.dart';
import 'src/theme.dart';
import 'src/ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const bool demoMode = bool.fromEnvironment('demo');
  late final AppData data;
  if (demoMode) {
    // `--dart-define=demo=true`: in-memory fake daemon, nothing to load.
    data = buildDemoAppData();
  } else {
    final ConnectionsStore connections = ConnectionsStore();
    await connections.init();
    data = AppData(
      connections: connections,
      selection: SelectionStore(),
    );
    // Connect every saved endpoint; failures land in their connection
    // statuses instead of blocking startup.
    unawaited(data.connectAll());
  }
  runApp(SpeedDialApp(data: data));
}

class SpeedDialApp extends StatelessWidget {
  const SpeedDialApp({super.key, required this.data});

  final AppData data;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      data: data,
      child: MaterialApp(
        title: 'SpeedDial',
        debugShowCheckedModeBanner: false,
        theme: buildSpeedDialLightTheme(),
        darkTheme: buildSpeedDialTheme(),
        themeMode: ThemeMode.dark,
        home: const SpeedDialShell(),
      ),
    );
  }
}
