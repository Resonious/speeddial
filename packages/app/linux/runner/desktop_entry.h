#ifndef RUNNER_DESKTOP_ENTRY_H_
#define RUNNER_DESKTOP_ENTRY_H_

#include <glib.h>

// Gives the window an icon on Wayland, where the toplevel has no icon of its
// own and shells (GNOME Shell, panels) look the app ID up as a desktop entry.
//
// Writes a hidden (NoDisplay) APPLICATION_ID.desktop entry and copies
// |icon_path| into the user's hicolor icon theme, both under the XDG user data
// dir. Files are only rewritten when their content changes. Does nothing when
// another data dir (e.g. an installed package) already provides the entry.
void desktop_entry_ensure(const gchar* executable_path,
                          const gchar* icon_path);

#endif  // RUNNER_DESKTOP_ENTRY_H_
