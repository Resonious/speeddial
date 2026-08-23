import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:speeddial_app/speeddial_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final ConnectionsStore connections = ConnectionsStore();
  await connections.init();
  await _seedProvisionedEndpoint(connections);

  final AppData data = AppData(
    connections: connections,
    selection: SelectionStore(),
  );
  await data.settings.init();
  if (connections.endpoints.length == 1) {
    data.selection.selectedDaemonId = connections.endpoints.single.id;
  }
  unawaited(data.connectAll());
  runApp(WearSpeedDialApp(data: data));
}

Future<void> _seedProvisionedEndpoint(ConnectionsStore connections) async {
  const String url = String.fromEnvironment('SPEEDDIAL_DAEMON_URL');
  if (url.isEmpty || connections.endpoints.isNotEmpty) return;
  const String token = String.fromEnvironment('SPEEDDIAL_DAEMON_TOKEN');
  const String configuredName = String.fromEnvironment('SPEEDDIAL_DAEMON_NAME');
  final String normalized = ConnectionsStore.normalizeEndpointUrl(url);
  final Uri? uri = Uri.tryParse(normalized);
  final String name = configuredName.isNotEmpty
      ? configuredName
      : uri?.host.isNotEmpty == true
      ? uri!.host
      : 'SpeedDial daemon';
  await connections.addEndpoint(
    id: 'wear-provisioned',
    name: name,
    url: url,
    token: token,
  );
}
