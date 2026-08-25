# SpeedDial Wear

Wear OS companion for the SpeedDial Android app. Daemon endpoints are configured
only on the paired phone and synchronized to the watch with the Wear OS Data
Layer. The watch sends daemon WebSocket frames through the paired phone, so the
connection uses the phone's active network and VPN routes. Tailscale-only daemons
work without being exposed publicly or installing Tailscale on the watch.

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
The paired phone must remain connected. Android shows a low-priority SpeedDial
notification on the phone while it is proxying an active watch connection.

Phone/watch proxy peers negotiate gzip without breaking staggered app updates;
large frames stay in the original format until both sides advertise support.
The watch requests compact 100-event history pages and keeps the three most
recent chat buffers in memory so reopening a conversation is immediate.

The watch also provides two optional system surfaces:

- **Recent SpeedDial sessions** Tile — the three sessions with the newest
  activity, with status color and a tap target that opens SpeedDial.
- **SpeedDial session counts** complication — the number of sessions currently
  running or waiting for approval, plus the number of unseen completed turns.
  Compatible watch faces can render these as blue and green weighted elements;
  short- and long-text formats remain available as fallbacks.

Add the Tile from the watch's Tile carousel and select the complication from a
compatible watch-face slot. Their last phone-synchronized snapshot remains
available while the Flutter app is closed; the complication refresh cadence is
limited to five minutes by Wear OS battery rules.
