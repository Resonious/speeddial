import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/companion/companion_endpoint_sync.dart';
import 'src/local_daemon/local_daemon.dart';
import 'src/local_daemon/mcp_entry.dart';
import 'src/scope.dart';
import 'src/theme.dart';
import 'src/ui/shell.dart';

Future<void> main(List<String> args) async {
  if (await runMcpIfRequested(args)) return;
  WidgetsFlutterBinding.ensureInitialized();
  const bool demoMode = bool.fromEnvironment('demo');
  late final AppData data;
  CompanionEndpointSync? companionSync;
  if (demoMode) {
    // `--dart-define=demo=true`: in-memory fake daemon, nothing to load.
    data = buildDemoAppData();
  } else {
    final ConnectionsStore connections = ConnectionsStore();
    await connections.init();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      companionSync = CompanionEndpointSync();
      await companionSync.startPhone(connections);
    }
    data = AppData(connections: connections, selection: SelectionStore());
    // Desktop builds start an in-process daemon for an out-of-the-box
    // experience; web/mobile skip this (unsupported) and rely on the user
    // adding a remote daemon. The embedded endpoint is non-persistent: its
    // URL carries an ephemeral port, so it is never written to prefs.
    if (embeddedDaemonSupported) {
      final LocalDaemonController localDaemon = createLocalDaemonController();
      data.localDaemon = localDaemon;
      final String? url = await localDaemon.start();
      if (url != null && !data.isDisposed) {
        await data.connections.addEndpoint(
          id: 'embedded',
          name: 'This computer',
          url: url,
          token: '',
          persist: false,
          embedded: true,
        );
        data.selection.selectedDaemonId = 'embedded';
      }
    }
    // Connect every saved endpoint; failures land in their connection
    // statuses instead of blocking startup.
    unawaited(data.connectAll());
  }
  await data.settings.init();
  runApp(SpeedDialApp(data: data, companionSync: companionSync));
}

class SpeedDialApp extends StatefulWidget {
  const SpeedDialApp({super.key, required this.data, this.companionSync});

  final AppData data;
  final CompanionEndpointSync? companionSync;

  @override
  State<SpeedDialApp> createState() => _SpeedDialAppState();
}

class _SpeedDialAppState extends State<SpeedDialApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Tear down the store graph and stop the embedded daemon (best-effort):
    // agent processes are killed and the WebSocket server closed.
    final AppData data = widget.data;
    widget.companionSync?.dispose();
    data.dispose();
    unawaited(data.stopLocalDaemon());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `detached` is the last notification before the process is killed; on
    // desktop there is no `paused`/`resumed`, so this is the only reliable
    // shutdown hook for the in-process daemon.
    if (state == AppLifecycleState.resumed) {
      widget.data.reconnectAll();
    } else if (state == AppLifecycleState.detached) {
      unawaited(widget.data.stopLocalDaemon());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      data: widget.data,
      child: ListenableBuilder(
        listenable: widget.data.settings,
        builder: (BuildContext context, Widget? _) {
          return MaterialApp(
            title: 'SpeedDial',
            debugShowCheckedModeBanner: false,
            theme: buildSpeedDialLightTheme(),
            darkTheme: buildSpeedDialTheme(),
            themeMode: widget.data.settings.themeMode,
            home: const SpeedDialShell(),
          );
        },
      ),
    );
  }
}
