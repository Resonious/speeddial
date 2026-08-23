# SpeedDial Wear

Standalone Wear OS client for existing SpeedDial daemons. It supports daemon
selection, project and session browsing, new sessions, live conversation
history, message sending, stopping turns, and permission responses.

The first launch offers a compact endpoint bootstrap form. For provisioned
builds, seed that endpoint at compile time:

```bash
export PATH="$HOME/p/flutter-sdk/bin:$PATH"
cd packages/wear
flutter run \
  --dart-define=SPEEDDIAL_DAEMON_URL=wss://daemon.example/ws \
  --dart-define=SPEEDDIAL_DAEMON_TOKEN=secret \
  --dart-define=SPEEDDIAL_DAEMON_NAME=Workstation
```

Build the standalone watch APK with `flutter build apk`. The daemon must be
reachable directly from the watch; a phone companion is not required. Dart
defines are embedded in the application binary, so provision a token this way
only for a private build. For a distributed build, enter the token on first
launch instead.
