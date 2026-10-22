#ifndef RUNNER_NATIVE_TITLE_BAR_H_
#define RUNNER_NATIVE_TITLE_BAR_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Puts SpeedDial's top bar controls (pane toggles, session title, daemon
// status, theme mode) into the window's GTK header bar, driven from Dart over
// the "speeddial/title_bar" method channel (lib/src/ui/native_title_bar.dart).
//
// The controls stay hidden until Dart attaches, so a build that never does
// just shows the plain title. |header_bar| may be null when the window uses a
// traditional title bar; Dart is then told to keep its own top bar.
void native_title_bar_install(GtkWindow* window, GtkHeaderBar* header_bar,
                              FlBinaryMessenger* messenger);

#endif  // RUNNER_NATIVE_TITLE_BAR_H_
