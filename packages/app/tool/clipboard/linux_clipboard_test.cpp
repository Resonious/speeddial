#include "../../linux/runner/rich_clipboard.h"

#include <cassert>
#include <string>

int main(int argc, char** argv) {
  gtk_init(&argc, &argv);
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  const std::string plain = u8"日本語 & café\n  second line";
  const std::string html = u8"<pre>日本語 &amp; café\n  second line</pre>";
  assert(rich_clipboard_write(plain.c_str(), html.c_str()));
  g_autofree gchar* actual_text = gtk_clipboard_wait_for_text(clipboard);
  assert(actual_text && std::string(actual_text) == plain);
  GtkSelectionData* data = gtk_clipboard_wait_for_contents(
      clipboard, gdk_atom_intern_static_string("text/html"));
  assert(data);
  const std::string actual_html(
      reinterpret_cast<const char*>(gtk_selection_data_get_data(data)),
      static_cast<size_t>(gtk_selection_data_get_length(data)));
  assert(actual_html == html);
  gtk_selection_data_free(data);
  // Replacement invokes the ownership callback; plain copy must remove HTML.
  gtk_clipboard_set_text(clipboard, "replacement", -1);
  assert(!gtk_clipboard_wait_is_target_available(
      clipboard, gdk_atom_intern_static_string("text/html")));
  assert(rich_clipboard_write("", "<pre></pre>"));
  gtk_clipboard_clear(clipboard);
}
