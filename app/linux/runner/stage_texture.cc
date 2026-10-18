// See stage_texture.h. The stage's library is loaded when the channel first asks for
// it, not linked: an app without it (or a machine where it will not load) still runs,
// and the show draws on its Flutter stage as before.
//
// The texture's populate runs on Flutter's raster thread with Flutter's GL context
// current; the first one starts the stage there (ws_attach_current makes a context
// sharing that one), and each hands over the newest finished frame. Every frame the
// stage finishes marks the texture changed, so the view draws it again.
#include "stage_texture.h"

#include <dlfcn.h>
#include <glib.h>

#include <cstdint>
#include <string>

namespace {

struct Stage {
  void* lib = nullptr;
  int (*attach)() = nullptr;
  const char* (*error)() = nullptr;
  void (*stop)() = nullptr;
  void (*shaders)(const char*) = nullptr;
  void (*size)(int, int, float) = nullptr;
  uint32_t (*latest)(int*, int*) = nullptr;
  void (*on_frame)(void (*)(void*), void*) = nullptr;
  std::string why;
};

Stage stage;

bool load_stage() {
  if (stage.lib) return true;
  // Beside the app's other libraries (bundle/lib, on the runner's rpath).
  stage.lib = dlopen("libwetowl_stage.so", RTLD_NOW | RTLD_GLOBAL);
  if (!stage.lib) {
    stage.why = dlerror();
    return false;
  }
  auto sym = [](const char* n) { return dlsym(stage.lib, n); };
  stage.attach = reinterpret_cast<int (*)()>(sym("ws_attach_current"));
  stage.error = reinterpret_cast<const char* (*)()>(sym("ws_error"));
  stage.stop = reinterpret_cast<void (*)()>(sym("ws_stop"));
  stage.shaders = reinterpret_cast<void (*)(const char*)>(sym("ws_shaders"));
  stage.size = reinterpret_cast<void (*)(int, int, float)>(sym("ws_size"));
  stage.latest = reinterpret_cast<uint32_t (*)(int*, int*)>(sym("ws_latest"));
  stage.on_frame = reinterpret_cast<void (*)(void (*)(void*), void*)>(sym("ws_on_frame"));
  if (!stage.attach || !stage.latest || !stage.size || !stage.on_frame || !stage.shaders) {
    stage.why = "libwetowl_stage.so is missing calls";
    dlclose(stage.lib);
    stage.lib = nullptr;
    return false;
  }
  // The scenes' sources: beside the app's data, or where WETOWL_STAGE_SHADERS says
  // (a checkout's app/shaders/show, to change a scene while it plays).
  const char* dir = g_getenv("WETOWL_STAGE_SHADERS");
  if (dir) {
    stage.shaders(dir);
  } else {
    g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
    g_autofree gchar* base = exe ? g_path_get_dirname(exe) : g_strdup(".");
    g_autofree gchar* data = g_build_filename(base, "data", "stage", nullptr);
    stage.shaders(data);
  }
  return true;
}

}  // namespace

G_DECLARE_FINAL_TYPE(WsTexture, ws_texture, WS, TEXTURE, FlTextureGL)

struct _WsTexture {
  FlTextureGL parent_instance;
  gboolean attached;
  gboolean failed;
};

G_DEFINE_TYPE(WsTexture, ws_texture, fl_texture_gl_get_type())

static gboolean ws_texture_populate(FlTextureGL* texture, uint32_t* target, uint32_t* name, uint32_t* width,
                                    uint32_t* height, GError** error) {
  WsTexture* self = WS_TEXTURE(texture);
  if (!self->attached && !self->failed) {
    if (stage.attach() != 0) {
      self->failed = TRUE;
      g_warning("stage: %s", stage.error ? stage.error() : "would not start");
    } else {
      self->attached = TRUE;
    }
  }
  int w = 0, h = 0;
  const uint32_t tex = self->attached ? stage.latest(&w, &h) : 0;
  if (tex == 0) {
    g_set_error(error, g_quark_from_static_string("wetowl-stage"), 1, "no frame yet");
    return FALSE;
  }
  *target = 0x0DE1;  // GL_TEXTURE_2D
  *name = tex;
  *width = static_cast<uint32_t>(w);
  *height = static_cast<uint32_t>(h);
  return TRUE;
}

static void ws_texture_class_init(WsTextureClass* klass) { FL_TEXTURE_GL_CLASS(klass)->populate = ws_texture_populate; }
static void ws_texture_init(WsTexture* self) {}

namespace {

FlTextureRegistrar* registrar = nullptr;
WsTexture* texture = nullptr;

void frame_done(void*) {
  // From the stage's thread: the registrar takes it from any thread.
  if (registrar && texture) fl_texture_registrar_mark_texture_frame_available(registrar, FL_TEXTURE(texture));
}

double num(FlValue* args, const char* key, double fallback) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return fallback;
  FlValue* v = fl_value_lookup_string(args, key);
  if (!v) return fallback;
  if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) return fl_value_get_float(v);
  if (fl_value_get_type(v) == FL_VALUE_TYPE_INT) return static_cast<double>(fl_value_get_int(v));
  return fallback;
}

void on_call(FlMethodChannel* channel, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "open") == 0) {
    if (!load_stage()) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new("no-stage", stage.why.c_str(), nullptr));
    } else {
      stage.size(static_cast<int>(num(args, "width", 1280)), static_cast<int>(num(args, "height", 720)),
                 static_cast<float>(num(args, "scale", 1)));
      if (!texture) {
        texture = WS_TEXTURE(g_object_new(ws_texture_get_type(), nullptr));
        fl_texture_registrar_register_texture(registrar, FL_TEXTURE(texture));
        stage.on_frame(frame_done, nullptr);
      }
      response = FL_METHOD_RESPONSE(
          fl_method_success_response_new(fl_value_new_int(fl_texture_get_id(FL_TEXTURE(texture)))));
    }
  } else if (g_strcmp0(method, "size") == 0) {
    if (stage.lib)
      stage.size(static_cast<int>(num(args, "width", 1280)), static_cast<int>(num(args, "height", 720)),
                 static_cast<float>(num(args, "scale", 1)));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "close") == 0) {
    if (texture) {
      stage.on_frame(nullptr, nullptr);
      stage.stop();
      fl_texture_registrar_unregister_texture(registrar, FL_TEXTURE(texture));
      g_clear_object(&texture);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

}  // namespace

void stage_texture_register(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) r = fl_plugin_registry_get_registrar_for_plugin(registry, "WetowlStage");
  registrar = fl_plugin_registrar_get_texture_registrar(r);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  static FlMethodChannel* channel = nullptr;
  channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(r), "wetowl/stage", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, on_call, nullptr, nullptr);
}
