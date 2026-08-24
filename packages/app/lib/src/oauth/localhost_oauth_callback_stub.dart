import 'localhost_oauth_callback_contract.dart';

const bool localhostOAuthCallbackSupported = false;

Future<LocalhostOAuthCallback> startLocalhostOAuthCallback() => Future.error(
  UnsupportedError('OAuth 2.1 (localhost) requires the native SpeedDial app'),
);
