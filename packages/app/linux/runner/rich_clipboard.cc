#include "rich_clipboard.h"

#include <cstring>

namespace {
struct RichContent {
  gchar* text;
  gchar* html;
};

void provide_data(GtkClipboard* clipboard, GtkSelectionData* selection,
                  guint info, gpointer data) {
  const RichContent* content = static_cast<RichContent*>(data);
  if (info == 1) {
    gtk_selection_data_set(selection, gtk_selection_data_get_target(selection),
        8, reinterpret_cast<const guchar*>(content->html),
        static_cast<gint>(std::strlen(content->html)));
  } else {
    gtk_selection_data_set_text(selection, content->text, -1);
  }
}

void clear_data(GtkClipboard* clipboard, gpointer data) {
  RichContent* content = static_cast<RichContent*>(data);
  g_free(content->text);
  g_free(content->html);
  g_free(content);
}

void handle_call(FlMethodChannel* channel, FlMethodCall* call, gpointer data) {
  if (std::strcmp(fl_method_call_get_name(call), "writeHtml") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  FlValue* args = fl_method_call_get_args(call);
  FlValue* text = nullptr;
  FlValue* html = nullptr;
  if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    text = fl_value_lookup_string(args, "text");
    html = fl_value_lookup_string(args, "html");
  }
  if (!text || !html || fl_value_get_type(text) != FL_VALUE_TYPE_STRING ||
      fl_value_get_type(html) != FL_VALUE_TYPE_STRING ||
      std::strlen(fl_value_get_string(html)) > G_MAXINT) {
    fl_method_call_respond_error(call, "invalid_arguments",
        "Expected text and html strings", nullptr, nullptr);
    return;
  }
  if (!rich_clipboard_write(fl_value_get_string(text), fl_value_get_string(html))) {
    fl_method_call_respond_error(call, "clipboard_write",
        "Could not write rich clipboard content", nullptr, nullptr);
    return;
  }
  fl_method_call_respond_success(call, nullptr, nullptr);
}
}  // namespace

bool rich_clipboard_write(const gchar* text, const gchar* html) {
  if (std::strlen(html) > G_MAXINT) return false;
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  RichContent* content = g_new0(RichContent, 1);
  content->text = g_strdup(text);
  content->html = g_strdup(html);
  g_autoptr(GtkTargetList) targets = gtk_target_list_new(nullptr, 0);
  gtk_target_list_add_text_targets(targets, 0);
  gtk_target_list_add(targets, gdk_atom_intern_static_string("text/html"), 0, 1);
  gint count = 0;
  GtkTargetEntry* entries = gtk_target_table_new_from_list(targets, &count);
  const gboolean success = gtk_clipboard_set_with_data(clipboard, entries,
      static_cast<guint>(count), provide_data, clear_data, content);
  gtk_target_table_free(entries, count);
  if (!success) {
    clear_data(clipboard, content);
    return false;
  }
  gtk_clipboard_set_can_store(clipboard, nullptr, 0);
  return true;
}

void rich_clipboard_install(GtkWidget* view, FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(messenger,
      "sh.speeddial/clipboard", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, handle_call, nullptr, nullptr);
  g_object_set_data_full(G_OBJECT(view), "speeddial-rich-clipboard", channel,
                        g_object_unref);
}
