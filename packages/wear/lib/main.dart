import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:speeddial_app/speeddial_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final ConnectionsStore connections = ConnectionsStore();
  await connections.init();
  final CompanionEndpointSync companionSync = CompanionEndpointSync();
  final PhoneProxyChannelFactory phoneProxy = PhoneProxyChannelFactory();

  final AppData data = AppData(
    connections: connections,
    selection: SelectionStore(),
    daemonChannelFactory: phoneProxy.connect,
    daemonHistoryDetail: SessionHistoryDetail.summary,
    chatHistoryPageSize: kWearHistoryPageSize,
    chatRetainedSessionLimit: kWearRetainedSessionLimit,
  );
  await companionSync.startWatch(connections, data.sessions);
  await data.settings.init();
  await data.drafts.init();
  if (connections.endpoints.length == 1) {
    data.selection.selectedDaemonId = connections.endpoints.single.id;
  }
  unawaited(companionSync.refreshWatchSessions(data));
  runApp(
    WearSpeedDialApp(
      data: data,
      companionSync: companionSync,
      phoneProxy: phoneProxy,
    ),
  );
}
