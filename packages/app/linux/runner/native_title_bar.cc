#include "native_title_bar.h"

#include <cstring>

namespace {

constexpr char kChannelName[] = "speeddial/title_bar";
constexpr char kDefaultTitle[] = "SpeedDial";

struct TitleBar {
  GtkWindow* window;
  // Null when the window has a traditional title bar.
  GtkHeaderBar* header_bar;
  FlMethodChannel* channel;
  GtkWidget* left_button;
  gulong left_handler;
  GtkWidget* right_button;
  gulong right_handler;
  GtkWidget* theme_button;
  GtkWidget* theme_image;
  GtkWidget* title_label;
  GtkWidget* subtitle_label;
};

void title_bar_free(gpointer data) {
  TitleBar* self = static_cast<TitleBar*>(data);
  g_clear_object(&self->channel);
  g_free(self);
}

void send(TitleBar* self, const char* method) {
  fl_method_channel_invoke_method(self->channel, method, nullptr, nullptr,
                                  nullptr, nullptr);
}

void set_toggle(GtkWidget* button, gulong handler, gboolean active) {
  g_signal_handler_block(button, handler);
  gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(button), active);
  g_signal_handler_unblock(button, handler);
}

// Dart owns the pane state, so a click undoes GTK's own flip and asks Dart to
// toggle; the next "update" sets the button to whatever Dart decided.
void left_toggled_cb(GtkToggleButton* button, gpointer user_data) {
  TitleBar* self = static_cast<TitleBar*>(user_data);
  set_toggle(GTK_WIDGET(button), self->left_handler,
             !gtk_toggle_button_get_active(button));
  send(self, "toggleLeft");
}

void right_toggled_cb(GtkToggleButton* button, gpointer user_data) {
  TitleBar* self = static_cast<TitleBar*>(user_data);
  set_toggle(GTK_WIDGET(button), self->right_handler,
             !gtk_toggle_button_get_active(button));
  send(self, "toggleRight");
}

void theme_clicked_cb(GtkButton* button, gpointer user_data) {
  send(static_cast<TitleBar*>(user_data), "cycleTheme");
}

// Header bar buttons must not take keyboard focus from the Flutter view, or
// typing in the composer stops after a click.
void make_unfocusable(GtkWidget* button) {
  gtk_widget_set_can_focus(button, FALSE);
}

GtkWidget* new_toggle(const char* icon_name, const char* tooltip) {
  GtkWidget* button = gtk_toggle_button_new();
  gtk_button_set_image(
      GTK_BUTTON(button),
      gtk_image_new_from_icon_name(icon_name, GTK_ICON_SIZE_BUTTON));
  gtk_style_context_add_class(gtk_widget_get_style_context(button),
                              "image-button");
  gtk_widget_set_tooltip_text(button, tooltip);
  gtk_widget_set_valign(button, GTK_ALIGN_CENTER);
  make_unfocusable(button);
  return button;
}

void build_controls(TitleBar* self) {
  GtkHeaderBar* bar = self->header_bar;

  self->left_button = new_toggle("sidebar-show-symbolic", "Toggle left rail");
  self->left_handler = g_signal_connect(self->left_button, "toggled",
                                        G_CALLBACK(left_toggled_cb), self);
  gtk_header_bar_pack_start(bar, self->left_button);

  // pack_end fills from the right edge inwards.
  self->right_button =
      new_toggle("sidebar-show-right-symbolic", "Toggle right panel");
  self->right_handler = g_signal_connect(self->right_button, "toggled",
                                         G_CALLBACK(right_toggled_cb), self);
  gtk_header_bar_pack_end(bar, self->right_button);

  self->theme_image = gtk_image_new_from_icon_name("display-brightness-symbolic",
                                                   GTK_ICON_SIZE_BUTTON);
  self->theme_button = gtk_button_new();
  gtk_button_set_image(GTK_BUTTON(self->theme_button), self->theme_image);
  gtk_style_context_add_class(gtk_widget_get_style_context(self->theme_button),
                              "image-button");
  gtk_widget_set_valign(self->theme_button, GTK_ALIGN_CENTER);
  make_unfocusable(self->theme_button);
  g_signal_connect(self->theme_button, "clicked", G_CALLBACK(theme_clicked_cb),
                   self);
  gtk_header_bar_pack_end(bar, self->theme_button);

  // A hand-built title so the subtitle can carry the coloured status dot.
  // The "title"/"subtitle" classes give it GTK's own header bar styling.
  GtkWidget* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  gtk_widget_set_valign(box, GTK_ALIGN_CENTER);
  self->title_label = gtk_label_new(kDefaultTitle);
  gtk_label_set_ellipsize(GTK_LABEL(self->title_label), PANGO_ELLIPSIZE_END);
  gtk_label_set_single_line_mode(GTK_LABEL(self->title_label), TRUE);
  gtk_style_context_add_class(gtk_widget_get_style_context(self->title_label),
                              "title");
  self->subtitle_label = gtk_label_new(nullptr);
  gtk_label_set_ellipsize(GTK_LABEL(self->subtitle_label),
                          PANGO_ELLIPSIZE_END);
  gtk_label_set_single_line_mode(GTK_LABEL(self->subtitle_label), TRUE);
  gtk_style_context_add_class(
      gtk_widget_get_style_context(self->subtitle_label), "subtitle");
  gtk_box_pack_start(GTK_BOX(box), self->title_label, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(box), self->subtitle_label, FALSE, FALSE, 0);
  gtk_widget_show(self->title_label);
  gtk_widget_show(box);
  gtk_header_bar_set_custom_title(bar, box);
}

FlValue* lookup(FlValue* map, const char* key, FlValueType type) {
  FlValue* value = fl_value_lookup_string(map, key);
  return value != nullptr && fl_value_get_type(value) == type ? value
                                                              : nullptr;
}

const gchar* lookup_string(FlValue* map, const char* key) {
  FlValue* value = lookup(map, key, FL_VALUE_TYPE_STRING);
  return value == nullptr ? nullptr : fl_value_get_string(value);
}

gboolean lookup_bool(FlValue* map, const char* key) {
  FlValue* value = lookup(map, key, FL_VALUE_TYPE_BOOL);
  return value != nullptr && fl_value_get_bool(value);
}

gboolean attach(TitleBar* self) {
  if (self->header_bar == nullptr) return FALSE;
  gtk_widget_show_all(self->left_button);
  gtk_widget_show_all(self->right_button);
  gtk_widget_show_all(self->theme_button);
  gtk_widget_show(self->subtitle_label);
  return TRUE;
}

void update(TitleBar* self, FlValue* args) {
  const gchar* title = lookup_string(args, "title");
  if (title == nullptr) title = kDefaultTitle;
  gtk_window_set_title(self->window, title);
  if (self->header_bar == nullptr) return;

  gtk_label_set_text(GTK_LABEL(self->title_label), title);

  const gchar* status = lookup_string(args, "status");
  FlValue* color = lookup(args, "statusColor", FL_VALUE_TYPE_INT);
  const guint rgb =
      color == nullptr ? 0x888888 : fl_value_get_int(color) & 0xffffff;
  g_autofree gchar* markup = g_markup_printf_escaped(
      "<span foreground=\"#%06x\">●</span> %s", rgb,
      status == nullptr ? "" : status);
  gtk_label_set_markup(GTK_LABEL(self->subtitle_label), markup);

  set_toggle(self->left_button, self->left_handler,
             lookup_bool(args, "leftOpen"));
  set_toggle(self->right_button, self->right_handler,
             lookup_bool(args, "rightOpen"));

  const gchar* mode = lookup_string(args, "themeMode");
  const char* icon = "display-brightness-symbolic";
  const char* tooltip = "Theme: System";
  if (g_strcmp0(mode, "light") == 0) {
    icon = "weather-clear-symbolic";
    tooltip = "Theme: Light";
  } else if (g_strcmp0(mode, "dark") == 0) {
    icon = "weather-clear-night-symbolic";
    tooltip = "Theme: Dark";
  }
  gtk_image_set_from_icon_name(GTK_IMAGE(self->theme_image), icon,
                               GTK_ICON_SIZE_BUTTON);
  gtk_widget_set_tooltip_text(self->theme_button, tooltip);

  // Follow the app's resolved brightness so the header bar matches it.
  g_object_set(gtk_widget_get_settings(GTK_WIDGET(self->window)),
               "gtk-application-prefer-dark-theme",
               lookup_bool(args, "dark"), nullptr);
}

void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                    gpointer user_data) {
  TitleBar* self = static_cast<TitleBar*>(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "attach") == 0) {
    g_autoptr(FlValue) result = fl_value_new_bool(attach(self));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (strcmp(method, "update") == 0) {
    if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "bad-args", "update expects a map", nullptr));
    } else {
      update(self, args);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond to %s: %s", method, error->message);
  }
}

}  // namespace

void native_title_bar_install(GtkWindow* window, GtkHeaderBar* header_bar,
                              FlBinaryMessenger* messenger) {
  TitleBar* self = g_new0(TitleBar, 1);
  self->window = window;
  self->header_bar = header_bar;
  if (header_bar != nullptr) build_controls(self);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel =
      fl_method_channel_new(messenger, kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, method_call_cb, self,
                                            nullptr);
  g_object_set_data_full(G_OBJECT(window), "speeddial-title-bar", self,
                         title_bar_free);
}
