/// Opens HTTP(S) links outside SpeedDial.
library;

import 'external_link_launcher_stub.dart'
    if (dart.library.io) 'external_link_launcher_native.dart'
    as platform;

Future<bool> launchExternalLink(Uri uri) => platform.launchExternalLink(uri);
