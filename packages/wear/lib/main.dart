import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:speeddial_app/speeddial_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final ConnectionsStore connections = ConnectionsStore();
  await connections.init();
  final CompanionEndpointSync companionSync = CompanionEndpointSync();
  await companionSync.startWatch(connections);
  final PhoneProxyChannelFactory phoneProxy = PhoneProxyChannelFactory();

  final AppData data = AppData(
    connections: connections,
    selection: SelectionStore(),
    daemonChannelFactory: phoneProxy.connect,
    daemonHistoryDetail: SessionHistoryDetail.summary,
    chatHistoryPageSize: kWearHistoryPageSize,
    chatRetainedSessionLimit: kWearRetainedSessionLimit,
  );
  await data.settings.init();
  if (connections.endpoints.length == 1) {
    data.selection.selectedDaemonId = connections.endpoints.single.id;
  }
  unawaited(data.connectAll());
  runApp(
    WearSpeedDialApp(
      data: data,
      companionSync: companionSync,
      phoneProxy: phoneProxy,
    ),
  );
}
