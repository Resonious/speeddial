/// Public surface shared with the standalone Wear OS target.
library;

export 'package:speeddial_protocol/speeddial_protocol.dart'
    show SessionHistoryDetail;

export 'src/companion/companion_endpoint_sync.dart'
    show CompanionEndpointSync, WearLaunchDestination, WearLaunchTarget;
export 'src/companion/phone_proxy_channel.dart' show PhoneProxyChannelFactory;
export 'src/scope.dart'
    show AppData, ConnectionsStore, DaemonEndpoint, SelectionStore;
export 'src/ui/wear/wear_app.dart'
    show WearSpeedDialApp, kWearHistoryPageSize, kWearRetainedSessionLimit;
