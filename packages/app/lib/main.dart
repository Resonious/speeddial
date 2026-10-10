import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'src/companion/companion_endpoint_sync.dart';
import 'src/local_daemon/local_daemon.dart';
import 'src/local_daemon/mcp_entry.dart';
import 'src/state/embedded_daemon_store.dart';
import 'src/state/session_link_store.dart';
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
    final EmbeddedDaemonStore embedded = EmbeddedDaemonStore();
    await embedded.init();
    data = AppData(
      connections: connections,
      selection: SelectionStore(),
      embeddedDaemon: embedded,
    );
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      companionSync = CompanionEndpointSync();
      await companionSync.startPhone(connections, data.sessions);
    }
    // Desktop builds start an in-process daemon for an out-of-the-box
    // experience; web/mobile skip this (unsupported) and rely on the user
    // adding a remote daemon. The embedded endpoint is non-persistent: its
    // URL carries an ephemeral port unless a fixed one is configured, so it
    // is never written to prefs.
    if (embeddedDaemonSupported) {
      final LocalDaemonController localDaemon = createLocalDaemonController();
      data.localDaemon = localDaemon;
      final EmbeddedDaemonConfig config = embedded.config;
      final String? url = await localDaemon.start(
        host: config.host,
        port: config.port,
        token: config.token,
      );
      if (url != null && !data.isDisposed) {
        await data.connections.addEndpoint(
          id: AppData.embeddedDaemonId,
          name: 'This computer',
          url: url,
          token: config.token,
          persist: false,
          embedded: true,
        );
        data.selection.selectedDaemonId = AppData.embeddedDaemonId;
      } else if (url == null && !data.isDisposed) {
        // Bind failure (e.g. configured port in use): surface it through the
        // store so the embedded-daemon settings page can show it.
        embedded.setLastError(
          localDaemon.lastError ?? StateError('unknown start failure'),
        );
      }
    }
    // Connect every saved endpoint; failures land in their connection
    // statuses instead of blocking startup.
    unawaited(
      companionSync == null
          ? data.connectAll()
          : _connectAndRefreshSessions(data),
    );
  }
  await data.settings.init();
  await data.drafts.init();
  await data.shares.init();
  if (!demoMode &&
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS)) {
    await data.shares.startMobile(
      ios: defaultTargetPlatform == TargetPlatform.iOS,
    );
    unawaited(_refreshShareCatalog(data));
  }
  runApp(SpeedDialApp(data: data, companionSync: companionSync));
}

Future<void> _refreshShareCatalog(AppData data) async {
  for (final DaemonEndpoint endpoint in data.connections.endpoints) {
    await data.projects.refresh(endpoint.id);
    try {
      await data.sessions.refresh(endpoint.id);
    } on Object catch (error) {
      debugPrint(
        'Share target session refresh failed for ${endpoint.id}: $error',
      );
    }
  }
}

Future<void> _connectAndRefreshSessions(AppData data) async {
  await data.connectAll();
  for (final DaemonEndpoint endpoint in data.connections.endpoints) {
    try {
      await data.sessions.refresh(endpoint.id);
    } on Object catch (error) {
      debugPrint('Initial session refresh failed for ${endpoint.id}: $error');
    }
  }
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
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();
  final GlobalKey<ScaffoldMessengerState> _messenger =
      GlobalKey<ScaffoldMessengerState>();
  late final SessionLinkStore _sessionLinks;

  @override
  void initState() {
    super.initState();
    _sessionLinks = SessionLinkStore(widget.data);
    WidgetsBinding.instance.addObserver(this);
    final Uri? initialUri = kIsWeb
        ? Uri.base
        : Uri.tryParse(
            WidgetsBinding.instance.platformDispatcher.defaultRouteName,
          );
    final SessionLink? link = initialUri == null
        ? null
        : SessionLink.fromUri(initialUri);
    if (link != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_openSessionLink(link));
      });
    }
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) =>
      _handleSessionUri(routeInformation.uri);

  @override
  Future<bool> didPushRoute(String route) async {
    final Uri? uri = Uri.tryParse(route);
    return uri != null && await _handleSessionUri(uri);
  }

  Future<bool> _handleSessionUri(Uri uri) async {
    final SessionLink? link = SessionLink.fromUri(uri);
    if (link == null) return false;
    unawaited(_openSessionLink(link));
    return true;
  }

  Future<void> _openSessionLink(SessionLink link) async {
    try {
      if (await _sessionLinks.open(link) && mounted) {
        _navigator.currentState?.popUntil(
          (Route<Object?> route) =>
              route.isFirst && !route.willHandlePopInternally,
        );
      }
    } on Object catch (error) {
      debugPrint('Session link failed: $error');
      if (!mounted) return;
      _messenger.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            error is SessionLinkException
                ? error.message
                : 'Could not open the session. Check your daemon connections.',
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionLinks.dispose();
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
      unawaited(widget.data.shares.resumeIOS());
    } else if (state == AppLifecycleState.detached) {
      unawaited(_flushDrafts());
      unawaited(widget.data.stopLocalDaemon());
    }
  }

  Future<void> _flushDrafts() async {
    try {
      await widget.data.drafts.flush();
    } on Object catch (error) {
      // DraftsStore already records the error for diagnostics; shutdown must
      // still continue so the embedded daemon is not left running.
      debugPrint('Draft flush failed during shutdown: $error');
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
            navigatorKey: _navigator,
            scaffoldMessengerKey: _messenger,
            // Session links select within the existing shell; they do not
            // create a second Navigator route on cold launch.
            initialRoute: '/',
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
