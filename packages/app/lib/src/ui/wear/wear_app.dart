import 'dart:async';

import 'package:flutter/material.dart';

import '../../companion/companion_endpoint_sync.dart';
import '../../companion/phone_proxy_channel.dart';
import '../../scope.dart';
import '../../theme.dart';
import 'wear_shell.dart';

/// Compact history/cache defaults for the constrained Wear transport.
const int kWearHistoryPageSize = 100;
const int kWearRetainedSessionLimit = 3;

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
    this.initialLaunchTarget,
    this.launchTargets,
  });

  final AppData data;
  final CompanionEndpointSync? companionSync;
  final PhoneProxyChannelFactory? phoneProxy;
  final WearLaunchTarget? initialLaunchTarget;
  final Stream<WearLaunchTarget>? launchTargets;

  @override
  State<WearSpeedDialApp> createState() => _WearSpeedDialAppState();
}

class _WearSpeedDialAppState extends State<WearSpeedDialApp>
    with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<WearLaunchTarget>? _launchSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _launchSubscription = widget.launchTargets?.listen(_queueLaunchTarget);
    final WearLaunchTarget? initialTarget = widget.initialLaunchTarget;
    if (initialTarget != null) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        _openLaunchTarget(initialTarget);
      });
    }
  }

  void _queueLaunchTarget(WearLaunchTarget target) {
    if (!mounted) return;
    if (_navigatorKey.currentState == null) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        _openLaunchTarget(target);
      });
      return;
    }
    _openLaunchTarget(target);
  }

  void _openLaunchTarget(WearLaunchTarget target) {
    if (!mounted) return;
    final NavigatorState? navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    final Widget page = switch (target.destination) {
      WearLaunchDestination.attention => WearAttentionPage(data: widget.data),
      WearLaunchDestination.session => WearSessionLaunchPage(
        data: widget.data,
        target: target,
      ),
    };
    navigator.push<void>(
      MaterialPageRoute<void>(builder: (BuildContext context) => page),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.data.reconnectAll();
      final CompanionEndpointSync? sync = widget.companionSync;
      if (sync != null) {
        unawaited(_refreshCompanion(sync));
      }
    } else if (state == AppLifecycleState.detached) {
      unawaited(_flushDrafts());
    }
  }

  Future<void> _refreshCompanion(CompanionEndpointSync sync) async {
    await sync.refreshWatch(widget.data.connections);
    await sync.refreshWatchSessions(widget.data);
  }

  Future<void> _flushDrafts() async {
    try {
      await widget.data.drafts.flush();
    } on Object catch (error) {
      debugPrint('Draft flush failed during shutdown: $error');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_launchSubscription?.cancel());
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
            navigatorKey: _navigatorKey,
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
