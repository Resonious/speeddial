/// Public surface shared with the standalone Wear OS target.
library;

export 'src/companion/companion_endpoint_sync.dart' show CompanionEndpointSync;
export 'src/scope.dart'
    show AppData, ConnectionsStore, DaemonEndpoint, SelectionStore;
export 'src/ui/wear/wear_app.dart' show WearSpeedDialApp;
