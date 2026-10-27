#include "text_drop.h"

namespace {

struct TextDrop {
  FlMethodChannel* channel;
  gboolean hovering;
};

void set_hover(TextDrop* self, gboolean hovering) {
  if (self->hovering == hovering) return;
  self->hovering = hovering;
  g_autoptr(FlValue) value = fl_value_new_bool(hovering);
  fl_method_channel_invoke_method(self->channel, "hover", value, nullptr,
                                nullptr, nullptr);
}

gboolean can_drop(GtkWidget* widget, GdkDragContext* context) {
  return (gdk_drag_context_get_actions(context) & GDK_ACTION_COPY) &&
         gtk_drag_dest_find_target(widget, context, nullptr) != GDK_NONE;
}

gboolean drag_motion(GtkWidget* widget, GdkDragContext* context, gint x,
                     gint y, guint time, gpointer data) {
  const gboolean accepted = can_drop(widget, context);
  set_hover(static_cast<TextDrop*>(data), accepted);
  gdk_drag_status(context, accepted ? GDK_ACTION_COPY : GdkDragAction(0), time);
  return TRUE;
}

void drag_leave(GtkWidget* widget, GdkDragContext* context, guint time,
                gpointer data) {
  set_hover(static_cast<TextDrop*>(data), FALSE);
}

gboolean drag_drop(GtkWidget* widget, GdkDragContext* context, gint x,
                   gint y, guint time, gpointer data) {
  set_hover(static_cast<TextDrop*>(data), FALSE);
  if (!can_drop(widget, context)) return FALSE;
  gtk_drag_get_data(widget, context,
                   gtk_drag_dest_find_target(widget, context, nullptr), time);
  return TRUE;
}

void drag_data_received(GtkWidget* widget, GdkDragContext* context, gint x,
                        gint y, GtkSelectionData* selection, guint info,
                        guint time, gpointer data) {
  TextDrop* self = static_cast<TextDrop*>(data);
  set_hover(self, FALSE);
  g_autofree gchar* text = nullptr;
  // Bound the bridge payload. Dart validates the URL before any daemon RPC.
  const gint length = gtk_selection_data_get_length(selection);
  if (length > 0 && length <= 65536) {
    if (info == 1) {
      text = reinterpret_cast<gchar*>(gtk_selection_data_get_text(selection));
    } else if (info == 2) {
      g_auto(GStrv) uris = gtk_selection_data_get_uris(selection);
      if (uris != nullptr && uris[0] != nullptr) text = g_strdup(uris[0]);
    }
  }
  if (text != nullptr) {
    g_autoptr(FlValue) value = fl_value_new_string(text);
    fl_method_channel_invoke_method(self->channel, "text", value, nullptr,
                                  nullptr, nullptr);
  }
  // Copy only: never ask the source to delete selected address-bar text.
  gtk_drag_finish(context, text != nullptr, FALSE, time);
}

void free_drop(gpointer data) {
  TextDrop* self = static_cast<TextDrop*>(data);
  g_clear_object(&self->channel);
  g_free(self);
}

}  // namespace

void text_drop_install(GtkWidget* view, FlBinaryMessenger* messenger) {
  TextDrop* self = g_new0(TextDrop, 1);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(
      messenger, "sh.speeddial/text-drop", FL_METHOD_CODEC(codec));
  g_object_set_data_full(G_OBJECT(view), "speeddial-text-drop", self, free_drop);
  gtk_drag_dest_set(view, GtkDestDefaults(0), nullptr, 0, GDK_ACTION_COPY);
  g_autoptr(GtkTargetList) targets = gtk_target_list_new(nullptr, 0);
  gtk_target_list_add_text_targets(targets, 1);
  gtk_target_list_add_uri_targets(targets, 2);
  gtk_drag_dest_set_target_list(view, targets);
  g_signal_connect(view, "drag-motion", G_CALLBACK(drag_motion), self);
  g_signal_connect(view, "drag-leave", G_CALLBACK(drag_leave), self);
  g_signal_connect(view, "drag-drop", G_CALLBACK(drag_drop), self);
  g_signal_connect(view, "drag-data-received", G_CALLBACK(drag_data_received), self);
}
