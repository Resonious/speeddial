import 'package:flutter/material.dart';

import 'src/scope.dart';
import 'src/theme.dart';
import 'src/ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const bool demoMode = bool.fromEnvironment('demo');
  if (demoMode) {
    // The --demo dart-define flag is accepted but not wired up yet; later
    // phases swap in the fake daemon client here.
    debugPrint('SpeedDial: demo mode requested but not implemented yet.');
  }

  final ConnectionsStore connections = ConnectionsStore();
  await connections.init();
  final AppData data = AppData(
    connections: connections,
    selection: SelectionStore(),
  );
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
