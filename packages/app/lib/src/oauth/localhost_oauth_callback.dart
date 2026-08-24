import 'localhost_oauth_callback_contract.dart';
import 'localhost_oauth_callback_stub.dart'
    if (dart.library.io) 'localhost_oauth_callback_native.dart'
    as platform;

export 'localhost_oauth_callback_contract.dart';

/// Whether this build can bind a native loopback HTTP listener.
bool get localhostOAuthCallbackSupported =>
    platform.localhostOAuthCallbackSupported;

/// Starts a one-shot callback listener when the current platform supports it.
Future<LocalhostOAuthCallback> startLocalhostOAuthCallback() =>
    platform.startLocalhostOAuthCallback();
