# SpeedDial app

See the repository README for daemon setup and desktop development.

## iPad and iPhone

With Flutter on PATH, run `flutter pub get` at the repository root, then from
`packages/app`:

```sh
flutter build ios --release
flutter install --release -d <device-id>
```

Open `ios/Runner.xcworkspace` to configure signing. The Runner target uses bundle
identifier `sh.speeddial.speeddialApp` and Nigel's personal team (`38MKN9SGLK`).
Xcode needs the corresponding Apple account signed in and a provisioning profile
that includes the target device. An unsigned compilation check is available with
`flutter build ios --release --no-codesign`.

Mobile clients connect to an external daemon. Add its reachable hostname or IP
address and token in the app, and allow local-network access when prompted.

On macOS, run daemon tests with `TMPDIR=/private/tmp dart test` from
`packages/daemon` to avoid `/var` versus `/private/var` temporary-path aliases.
