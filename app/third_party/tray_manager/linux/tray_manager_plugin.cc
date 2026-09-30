#include "include/tray_manager/tray_manager_plugin.h"

#include <dlfcn.h>
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>

#include <algorithm>
#include <cstring>
#include <map>

// WetOwl: AppIndicator is loaded when the tray is first asked for, not linked. Linked,
// a Linux without it could not start the app at all — the dynamic linker refuses before
// a line of it runs — and it is not on every desktop (Arch installs it only on request).
// Loaded here, a machine without it answers setIcon with an error, and the app goes on
// with no icon (lib/src/ui/tray.dart keeps the close button closing, then). The five
// calls below are all the plugin uses, with the two enums' values as both libraries
// (Ayatana's and the older libappindicator) define them. See WETOWL.md.
typedef struct _AppIndicator AppIndicator;
typedef enum {
  APP_INDICATOR_CATEGORY_APPLICATION_STATUS = 0,
} AppIndicatorCategory;
typedef enum {
  APP_INDICATOR_STATUS_PASSIVE = 0,
  APP_INDICATOR_STATUS_ACTIVE = 1,
} AppIndicatorStatus;

static AppIndicator* (*app_indicator_new)(const gchar*, const gchar*,
                                          AppIndicatorCategory) = nullptr;
static void (*app_indicator_set_status)(AppIndicator*,
                                        AppIndicatorStatus) = nullptr;
static void (*app_indicator_set_menu)(AppIndicator*, GtkMenu*) = nullptr;
static void (*app_indicator_set_icon_full)(AppIndicator*, const gchar*,
                                           const gchar*) = nullptr;
static void (*app_indicator_set_label)(AppIndicator*, const gchar*,
                                       const gchar*) = nullptr;

// Whether the library is there, loading it the first time. Tried once.
static bool have_appindicator() {
  static int state = 0;  // 0 not tried, 1 loaded, -1 not there
  if (state != 0) return state > 0;
  state = -1;
  const char* names[] = {"libayatana-appindicator3.so.1",
                         "libappindicator3.so.1"};
  for (const char* name : names) {
    void* lib = dlopen(name, RTLD_NOW | RTLD_LOCAL);
    if (lib == nullptr) continue;
    app_indicator_new = reinterpret_cast<decltype(app_indicator_new)>(
        dlsym(lib, "app_indicator_new"));
    app_indicator_set_status =
        reinterpret_cast<decltype(app_indicator_set_status)>(
            dlsym(lib, "app_indicator_set_status"));
    app_indicator_set_menu = reinterpret_cast<decltype(app_indicator_set_menu)>(
        dlsym(lib, "app_indicator_set_menu"));
    app_indicator_set_icon_full =
        reinterpret_cast<decltype(app_indicator_set_icon_full)>(
            dlsym(lib, "app_indicator_set_icon_full"));
    app_indicator_set_label =
        reinterpret_cast<decltype(app_indicator_set_label)>(
            dlsym(lib, "app_indicator_set_label"));
    if (app_indicator_new && app_indicator_set_status &&
        app_indicator_set_menu && app_indicator_set_icon_full &&
        app_indicator_set_label) {
      state = 1;
      return true;
    }
    dlclose(lib);
  }
  return false;
}

static FlMethodResponse* no_appindicator() {
  return FL_METHOD_RESPONSE(fl_method_error_response_new(
      "no_appindicator",
      "no AppIndicator library (libayatana-appindicator3.so.1 or "
      "libappindicator3.so.1) on this system",
      nullptr));
}

#define TRAY_MANAGER_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), tray_manager_plugin_get_type(), \
                              TrayManagerPlugin))

TrayManagerPlugin* plugin_instance;

AppIndicator* indicator = nullptr;
GtkWidget* menu = nullptr;

struct _TrayManagerPlugin {
  GObject parent_instance;
  FlPluginRegistrar* registrar;
  FlMethodChannel* channel;
};

G_DEFINE_TYPE(TrayManagerPlugin, tray_manager_plugin, g_object_get_type())

// Gets the window being controlled.
GtkWindow* get_window(TrayManagerPlugin* self) {
  FlView* view = fl_plugin_registrar_get_view(self->registrar);
  if (view == nullptr)
    return nullptr;

  return GTK_WINDOW(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

void _on_activate(GtkMenuItem* item, gpointer user_data) {
  gint id = GPOINTER_TO_INT(user_data);

  g_autoptr(FlValue) result_data = fl_value_new_map();
  fl_value_set_string_take(result_data, "id", fl_value_new_int(id));
  fl_method_channel_invoke_method(plugin_instance->channel,
                                  "onTrayMenuItemClick", result_data, nullptr,
                                  nullptr, nullptr);
}

GtkWidget* _create_menu(FlValue* args) {
  FlValue* items_value = fl_value_lookup_string(args, "items");

  GtkWidget* menu = gtk_menu_new();
  for (gint i = 0; i < fl_value_get_length(items_value); i++) {
    FlValue* item_value = fl_value_get_list_value(items_value, i);
    const int id = fl_value_get_int(fl_value_lookup_string(item_value, "id"));
    const char* type =
        fl_value_get_string(fl_value_lookup_string(item_value, "type"));
    const char* label =
        fl_value_get_string(fl_value_lookup_string(item_value, "label"));
    const bool disabled =
        fl_value_get_bool(fl_value_lookup_string(item_value, "disabled"));

    gint item_id = id;

    if (strcmp(type, "separator") == 0) {
      gtk_menu_shell_append(GTK_MENU_SHELL(menu),
                            gtk_separator_menu_item_new());
    } else {
      GtkWidget* item = gtk_menu_item_new_with_label(label);

      if (disabled) {
        gtk_widget_set_sensitive(item, FALSE);
      }

      if (strcmp(type, "checkbox") == 0) {
        item = gtk_check_menu_item_new_with_label(label);
        const auto checked_value =
            fl_value_lookup_string(item_value, "checked");
        if (checked_value != nullptr) {
          const auto checked = fl_value_get_bool(checked_value);
          gtk_check_menu_item_set_active((GtkCheckMenuItem*)item, checked);
        }
      } else if (strcmp(type, "submenu") == 0) {
        GtkWidget* sub_menu =
            _create_menu(fl_value_lookup_string(item_value, "submenu"));
        gtk_menu_item_set_submenu(GTK_MENU_ITEM(item), sub_menu);
      }

      g_signal_connect(G_OBJECT(item), "activate", G_CALLBACK(_on_activate),
                       GINT_TO_POINTER(item_id));

      gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
    }
  }
  return menu;
}

static FlMethodResponse* destroy(TrayManagerPlugin* self, FlValue* args) {
  if (indicator != nullptr && have_appindicator()) {
    app_indicator_set_status(indicator, APP_INDICATOR_STATUS_PASSIVE);
  }
  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

static FlMethodResponse* set_icon(TrayManagerPlugin* self, FlValue* args) {
  if (!have_appindicator()) return no_appindicator();
  const char* id = fl_value_get_string(fl_value_lookup_string(args, "id"));
  const char* icon_path =
      fl_value_get_string(fl_value_lookup_string(args, "iconPath"));

  if (!menu)
    menu = gtk_menu_new();

  if (!indicator) {
    indicator = app_indicator_new(id, icon_path,
                                  APP_INDICATOR_CATEGORY_APPLICATION_STATUS);

    app_indicator_set_menu(indicator, GTK_MENU(menu));
    gtk_widget_show_all(menu);
  }

  app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE);
  app_indicator_set_icon_full(indicator, icon_path, "");

  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

static FlMethodResponse* set_title(TrayManagerPlugin* self, FlValue* args) {
  // WetOwl: and not before there is an indicator to set it on.
  if (indicator == nullptr) return no_appindicator();
  const char* title =
      fl_value_get_string(fl_value_lookup_string(args, "title"));

  app_indicator_set_label(indicator, title, NULL);

  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

static FlMethodResponse* set_context_menu(TrayManagerPlugin* self,
                                          FlValue* args) {
  // WetOwl: likewise — upstream handed a null indicator to AppIndicator.
  if (indicator == nullptr) return no_appindicator();
  menu = _create_menu(fl_value_lookup_string(args, "menu"));

  app_indicator_set_menu(indicator, GTK_MENU(menu));
  gtk_widget_show_all(menu);

  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

// Called when a method call is received from Flutter.
static void tray_manager_plugin_handle_method_call(TrayManagerPlugin* self,
                                                   FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(method, "destroy") == 0) {
    response = destroy(self, args);
  } else if (strcmp(method, "setIcon") == 0) {
    response = set_icon(self, args);
  } else if (strcmp(method, "setTitle") == 0) {
    response = set_title(self, args);
  } else if (strcmp(method, "setContextMenu") == 0) {
    response = set_context_menu(self, args);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void tray_manager_plugin_dispose(GObject* object) {
  G_OBJECT_CLASS(tray_manager_plugin_parent_class)->dispose(object);
}

static void tray_manager_plugin_class_init(TrayManagerPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = tray_manager_plugin_dispose;
}

static void tray_manager_plugin_init(TrayManagerPlugin* self) {}

static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  TrayManagerPlugin* plugin = TRAY_MANAGER_PLUGIN(user_data);
  tray_manager_plugin_handle_method_call(plugin, method_call);
}

void tray_manager_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  TrayManagerPlugin* plugin = TRAY_MANAGER_PLUGIN(
      g_object_new(tray_manager_plugin_get_type(), nullptr));

  plugin->registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "tray_manager", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      plugin->channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  plugin_instance = plugin;

  g_object_unref(plugin);
}
