# SpeedDial app

See the repository README for daemon setup and desktop development.

## iPad and iPhone

With Flutter on PATH, run `flutter pub get` at the repository root, then from
`packages/app`:

```sh
flutter build ios --release
xcrun devicectl device install app --device <device-id> build/ios/iphoneos/Runner.app
```

Use `devicectl` to update an existing installation in place. `flutter install`
uninstalls the previous build and clears the app's saved daemon connections.
Back up the app's preferences before changing the installed build. Open
`ios/Runner.xcworkspace` to configure signing. The Runner target uses bundle
identifier `sh.speeddial.speeddialApp` and Nigel's personal team (`38MKN9SGLK`).
Xcode needs the corresponding Apple account signed in and a provisioning profile
that includes the target device. An unsigned compilation check is available with
`flutter build ios --release --no-codesign`.

Mobile clients connect to an external daemon. Add its reachable hostname or IP
address and token in the app, and allow local-network access when prompted.

On macOS, run daemon tests with `TMPDIR=/private/tmp dart test` from
`packages/daemon` to avoid `/var` versus `/private/var` temporary-path aliases.

## iOS sharing

The iOS runner includes a Share extension and shares only project labels, IDs,
and queued files through `group.sh.speeddial.speeddialApp`. No daemon tokens or
session credentials are available to the extension. Both targets need App Groups
enabled in their provisioning profiles.

Share one file or photo up to 8 MiB from another app, choose SpeedDial, then
choose a project or **Attach later in SpeedDial**. Tap Done and open SpeedDial.
A project selection creates a new session with its remembered settings; Attach
later shows the floating attachment UI. Review the attachment and send it from
the composer. The share sheet itself never sends a message to an agent.

Shares wait in an atomic disk inbox (up to 20 files) until SpeedDial launches or
resumes. One file is imported at a time; attaching or dismissing it imports the
next. Once imported, attachments live in memory and are lost if the app is
terminated before sending. The extension cannot launch the app through Apple's
supported Share extension APIs.
