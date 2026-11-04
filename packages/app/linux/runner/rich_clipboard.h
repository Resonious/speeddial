#ifndef SPEEDDIAL_RICH_CLIPBOARD_H_
#define SPEEDDIAL_RICH_CLIPBOARD_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

bool rich_clipboard_write(const gchar* text, const gchar* html);
void rich_clipboard_install(GtkWidget* view, FlBinaryMessenger* messenger);

#endif
