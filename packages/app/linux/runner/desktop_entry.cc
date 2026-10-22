#include "desktop_entry.h"

#include <gio/gdesktopappinfo.h>

#include <cstring>

namespace {

// Writes |contents| to |path| unless the file already holds exactly that.
void write_if_changed(const gchar* path, const gchar* contents, gsize length) {
  g_autofree gchar* existing = nullptr;
  gsize existing_length = 0;
  if (g_file_get_contents(path, &existing, &existing_length, nullptr) &&
      existing_length == length && memcmp(existing, contents, length) == 0) {
    return;
  }

  g_autofree gchar* directory = g_path_get_dirname(path);
  if (g_mkdir_with_parents(directory, 0755) != 0) {
    g_warning("Failed to create %s", directory);
    return;
  }
  g_autoptr(GError) error = nullptr;
  if (!g_file_set_contents(path, contents, length, &error)) {
    g_warning("Failed to write %s: %s", path, error->message);
  }
}

// Quotes |path| as one Exec argument, then escapes it as a desktop entry
// string value (which doubles every backslash again).
gchar* exec_argument(const gchar* path) {
  GString* quoted = g_string_new("\"");
  for (const gchar* c = path; *c != '\0'; c++) {
    if (strchr("\"`$\\", *c) != nullptr) g_string_append(quoted, "\\\\");
    if (*c == '\\') g_string_append_c(quoted, '\\');
    g_string_append_c(quoted, *c);
  }
  g_string_append_c(quoted, '"');
  return g_string_free(quoted, FALSE);
}

}  // namespace

void desktop_entry_ensure(const gchar* executable_path,
                          const gchar* icon_path) {
  const gchar* data_dir = g_get_user_data_dir();
  g_autofree gchar* entry_path = g_build_filename(
      data_dir, "applications", APPLICATION_ID ".desktop", nullptr);

  g_autoptr(GDesktopAppInfo) installed =
      g_desktop_app_info_new(APPLICATION_ID ".desktop");
  if (installed != nullptr &&
      g_strcmp0(g_desktop_app_info_get_filename(installed), entry_path) != 0) {
    return;
  }

  g_autofree gchar* icon = nullptr;
  gsize icon_length = 0;
  g_autoptr(GError) error = nullptr;
  if (!g_file_get_contents(icon_path, &icon, &icon_length, &error)) {
    g_warning("Failed to read the application icon: %s", error->message);
    return;
  }
  g_autofree gchar* themed_icon_path =
      g_build_filename(data_dir, "icons", "hicolor", "512x512", "apps",
                       APPLICATION_ID ".png", nullptr);
  write_if_changed(themed_icon_path, icon, icon_length);

  // Hidden from launchers: Exec points at whichever build ran last, which may
  // be a throwaway checkout. The entry exists so shells can match the window.
  g_autofree gchar* exec = exec_argument(executable_path);
  g_autofree gchar* entry = g_strdup_printf(
      "[Desktop Entry]\n"
      "Type=Application\n"
      "Name=SpeedDial\n"
      "Comment=Fast agent development environment\n"
      "Exec=%s\n"
      "Icon=" APPLICATION_ID "\n"
      "StartupWMClass=" APPLICATION_ID "\n"
      "Categories=Development;\n"
      "NoDisplay=true\n",
      exec);
  write_if_changed(entry_path, entry, strlen(entry));
}
