# SpeedDial Wear

Wear OS companion for the SpeedDial Android app. Daemon endpoints are configured
only on the paired phone and synchronized to the watch with the Wear OS Data
Layer. The watch then connects directly to the synchronized daemon URL.

The phone and watch APKs use the same Android application id and must be signed
with the same certificate. Install both debug APKs from the same checkout:

```bash
export PATH="$HOME/p/flutter-sdk/bin:$PATH"
export ANDROID_HOME="$HOME/Android/Sdk"

(cd packages/app && flutter build apk --debug)
(cd packages/wear && flutter build apk --debug)
```

Phone APK:

```text
packages/app/build/app/outputs/flutter-apk/app-debug.apk
```

Watch APK:

```text
packages/wear/build/app/outputs/flutter-apk/app-debug.apk
```

After installing both APKs, open SpeedDial on the phone once. Adding, editing,
or removing a daemon publishes the latest endpoint snapshot to the paired watch.
The daemon must still be reachable directly from the watch, so do not configure
`localhost` unless the daemon runs on the watch itself.
