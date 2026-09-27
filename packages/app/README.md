# speeddial_app

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## iOS sharing

The iOS runner includes a native ShareExtension and shares only project labels,
IDs, and queued files through `group.sh.speeddial.speeddialApp`. No daemon tokens
or session credentials are available to the extension. Both targets need App
Groups enabled in their provisioning profiles; configure the same team and group
for Runner and ShareExtension if changing the bundle identifiers.

Share **one file or photo up to 8 MiB** from another app, choose SpeedDial, then
choose a project or **Attach later in SpeedDial**. Tap Done and open SpeedDial.
A project selection creates a new session with its remembered settings; Attach
later shows the existing floating attachment UI. Review the attachment and send
it from the composer. Nothing is sent to an agent from the share sheet itself.

Shares wait in an atomic disk inbox (up to 20 files) until SpeedDial launches or
resumes. Only one floating file is imported at a time; attaching or dismissing it
imports the next. Once imported, attachments live in memory, like Android, and
are lost if the app is terminated before sending. The extension cannot launch
the app through Apple's supported Share extension APIs.

Build from this directory with `flutter build ios --release`. Validate on a device
by sharing from Files and Photos with SpeedDial closed and already running, using
both target choices, dismissing a share, and trying an oversized file. The native
inbox checks can run without a simulator using `scripts/test_ios_share_inbox.sh`
from the repository root.
