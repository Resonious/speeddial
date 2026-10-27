#ifndef SPEEDDIAL_TEXT_DROP_H_
#define SPEEDDIAL_TEXT_DROP_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// External text/URI drops on the Flutter view, forwarded to Dart.
void text_drop_install(GtkWidget* view, FlBinaryMessenger* messenger);

#endif
