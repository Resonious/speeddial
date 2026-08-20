/// Conditional import: desktop builds wire the native in-process daemon,
/// web/mobile fall back to the stub. The app imports only this file.
///
/// [LocalDaemonController] (the interface) and `embeddedDaemonSupported` are
/// always available; the platform-specific controller factory is selected by
/// the conditional import below.
library;

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;

import 'local_daemon_controller.dart';
// The conditional import selects the native impl (desktop, `dart:io` present)
// or the stub (web/mobile). Both define the same top-level factory.
import 'local_daemon_stub.dart'
    if (dart.library.io) 'local_daemon_native.dart' as impl;

export 'local_daemon_controller.dart';

/// True when this build embeds its own daemon.
///
/// `false` on the web (no `dart:io`) and on mobile (the daemon shells out to
/// `git`/`gh` and agent CLIs, which are not present on iOS/Android). `true`
/// on the three desktop platforms. Computed from compile-time-safe platform
/// identifies (no `dart:io` import here).
bool get embeddedDaemonSupported {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows;
}

/// The platform-appropriate controller. Constructed once per app; the caller
/// owns its lifecycle (start on launch, stop on dispose).
LocalDaemonController createLocalDaemonController() =>
    impl.platformControllerImpl();
