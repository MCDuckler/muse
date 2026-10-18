// See stage_texture.h. The stage's library (wetowl_stage.dll, beside the app, with
// ANGLE's libEGL.dll and libGLESv2.dll) is loaded when the channel first asks for it,
// not linked: an app without it (or a machine where it will not load) still runs,
// and the show draws on its Flutter stage as before.
//
// Flutter draws on Windows through an ANGLE of its own, inside flutter_windows.dll,
// whose context nothing outside can share; so the stage draws in an ANGLE of its own
// too, on a thread of its own, and each finished frame crosses over as a Direct3D
// texture shared by handle — opened by Flutter's Direct3D on its raster thread, from
// the descriptor callback here — or, where the card will not share, as pixels. Every
// frame the stage finishes marks the texture changed, so the view draws it again.
//
// The texture goes through Flutter's C calls (flutter_texture_registrar.h), not the
// C++ wrapper's TextureRegistrar: that one is the plugins' library, which the app is
// not linked with; the channel is the app wrapper's.
#include "stage_texture.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_plugin_registrar.h>
#include <flutter_texture_registrar.h>
#include <flutter_windows.h>
#include <windows.h>

#include <cstdint>
#include <memory>
#include <string>

namespace {

struct Stage {
  HMODULE lib = nullptr;
  int (*attach)() = nullptr;
  int (*features)() = nullptr;
  const char* (*error)() = nullptr;
  void (*stop)() = nullptr;
  void (*shaders)(const char*) = nullptr;
  void (*size)(int, int, float) = nullptr;
  void* (*share)(int*, int*) = nullptr;
  const uint8_t* (*pixels)(int*, int*) = nullptr;
  void (*pixels_done)() = nullptr;
  void (*on_frame)(void (*)(void*), void*) = nullptr;
  std::string why;
};

Stage stage;

std::string narrow(const std::wstring& w) {
  if (w.empty()) return {};
  const int n = ::WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
  std::string s(n, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), s.data(), n, nullptr, nullptr);
  return s;
}

// The folder the app runs from, where its libraries and its data are.
std::wstring exe_dir() {
  wchar_t path[MAX_PATH];
  const DWORD n = ::GetModuleFileNameW(nullptr, path, MAX_PATH);
  std::wstring p(path, n);
  const auto slash = p.find_last_of(L"\\/");
  return slash == std::wstring::npos ? L"." : p.substr(0, slash);
}

std::string last_error() {
  const DWORD code = ::GetLastError();
  wchar_t* text = nullptr;
  const DWORD n = ::FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                                   nullptr, code, 0, reinterpret_cast<wchar_t*>(&text), 0, nullptr);
  std::string s = n ? narrow(std::wstring(text, n)) : "error " + std::to_string(code);
  if (text) ::LocalFree(text);
  while (!s.empty() && (s.back() == '\r' || s.back() == '\n' || s.back() == ' ')) s.pop_back();
  return s;
}

bool load_stage() {
  if (stage.lib) return true;
  // Beside the app, and its own needs (ANGLE) found beside it too, whatever the
  // working directory.
  const std::wstring dir = exe_dir();
  stage.lib = ::LoadLibraryExW((dir + L"\\wetowl_stage.dll").c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
  if (!stage.lib) {
    stage.why = "wetowl_stage.dll: " + last_error();
    return false;
  }
  auto sym = [](const char* n) { return reinterpret_cast<void*>(::GetProcAddress(stage.lib, n)); };
  stage.attach = reinterpret_cast<int (*)()>(sym("ws_attach_shared"));
  stage.features = reinterpret_cast<int (*)()>(sym("ws_features"));
  stage.error = reinterpret_cast<const char* (*)()>(sym("ws_error"));
  stage.stop = reinterpret_cast<void (*)()>(sym("ws_stop"));
  stage.shaders = reinterpret_cast<void (*)(const char*)>(sym("ws_shaders"));
  stage.size = reinterpret_cast<void (*)(int, int, float)>(sym("ws_size"));
  stage.share = reinterpret_cast<void* (*)(int*, int*)>(sym("ws_share"));
  stage.pixels = reinterpret_cast<const uint8_t* (*)(int*, int*)>(sym("ws_pixels"));
  stage.pixels_done = reinterpret_cast<void (*)()>(sym("ws_pixels_done"));
  stage.on_frame = reinterpret_cast<void (*)(void (*)(void*), void*)>(sym("ws_on_frame"));
  if (!stage.attach || !stage.features || !stage.size || !stage.on_frame || !stage.shaders || !stage.share || !stage.pixels ||
      !stage.pixels_done || !stage.stop || !stage.error) {
    stage.why = "wetowl_stage.dll is missing calls";
    ::FreeLibrary(stage.lib);
    stage.lib = nullptr;
    return false;
  }
  // The scenes' sources: beside the app's data, or where WETOWL_STAGE_SHADERS says
  // (a checkout's app/shaders/show, to change a scene while it plays).
  wchar_t env[MAX_PATH];
  const DWORD n = ::GetEnvironmentVariableW(L"WETOWL_STAGE_SHADERS", env, MAX_PATH);
  if (n > 0 && n < MAX_PATH) {
    stage.shaders(narrow(std::wstring(env, n)).c_str());
  } else {
    stage.shaders(narrow(dir + L"\\data\\stage").c_str());
  }
  return true;
}

FlutterDesktopTextureRegistrarRef registrar = nullptr;
int64_t texture_id = -1;
bool attached = false;
bool failed = false;
FlutterDesktopGpuSurfaceDescriptor descriptor = {};
FlutterDesktopPixelBuffer pixel_buffer = {};

void frame_done(void*) {
  // From the stage's thread: the registrar takes it from any thread.
  if (registrar && texture_id >= 0) FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(registrar, texture_id);
}

// On Flutter's raster thread: the newest finished frame, as the Direct3D texture
// Flutter opens by handle (the same handle, while the frame is the same).
const FlutterDesktopGpuSurfaceDescriptor* obtain_surface(size_t, size_t, void*) {
  int w = 0, h = 0;
  void* handle = stage.share(&w, &h);
  if (!handle) return nullptr;
  descriptor.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
  descriptor.handle = handle;
  descriptor.width = descriptor.visible_width = static_cast<size_t>(w);
  descriptor.height = descriptor.visible_height = static_cast<size_t>(h);
  descriptor.format = kFlutterDesktopPixelFormatBGRA8888;
  descriptor.release_callback = nullptr;
  descriptor.release_context = nullptr;
  return &descriptor;
}

// The same, as pixels Flutter copies into a texture of its own; the stage keeps
// them still until the copy is done.
const FlutterDesktopPixelBuffer* obtain_pixels(size_t, size_t, void*) {
  int w = 0, h = 0;
  const uint8_t* rgba = stage.pixels(&w, &h);
  if (!rgba) return nullptr;
  pixel_buffer.buffer = rgba;
  pixel_buffer.width = static_cast<size_t>(w);
  pixel_buffer.height = static_cast<size_t>(h);
  pixel_buffer.release_callback = [](void*) { stage.pixels_done(); };
  pixel_buffer.release_context = nullptr;
  return &pixel_buffer;
}

double num(const flutter::EncodableMap* args, const char* key, double fallback) {
  if (!args) return fallback;
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) return fallback;
  if (const auto* d = std::get_if<double>(&it->second)) return *d;
  if (const auto* i = std::get_if<int32_t>(&it->second)) return static_cast<double>(*i);
  if (const auto* l = std::get_if<int64_t>(&it->second)) return static_cast<double>(*l);
  return fallback;
}

void on_call(const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
  const std::string& method = call.method_name();
  if (method == "open") {
    if (!load_stage()) {
      result->Error("no-stage", stage.why);
      return;
    }
    stage.size(static_cast<int>(num(args, "width", 1280)), static_cast<int>(num(args, "height", 720)),
               static_cast<float>(num(args, "scale", 1)));
    if (!attached) {
      if (failed || stage.attach() != 0) {
        failed = true;
        result->Error("no-stage", std::string("the stage would not start: ") + stage.error());
        return;
      }
      attached = true;
    }
    if (texture_id < 0) {
      // Shared by handle where the card will; pixels otherwise (ws_features).
      FlutterDesktopTextureInfo info = {};
      if (stage.features() & 2) {
        info.type = kFlutterDesktopGpuSurfaceTexture;
        info.gpu_surface_config.struct_size = sizeof(FlutterDesktopGpuSurfaceTextureConfig);
        info.gpu_surface_config.type = kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle;
        info.gpu_surface_config.callback = obtain_surface;
        info.gpu_surface_config.user_data = nullptr;
      } else {
        info.type = kFlutterDesktopPixelBufferTexture;
        info.pixel_buffer_config.callback = obtain_pixels;
        info.pixel_buffer_config.user_data = nullptr;
      }
      texture_id = FlutterDesktopTextureRegistrarRegisterExternalTexture(registrar, &info);
      stage.on_frame(frame_done, nullptr);
    }
    result->Success(flutter::EncodableValue(texture_id));
  } else if (method == "size") {
    if (stage.lib)
      stage.size(static_cast<int>(num(args, "width", 1280)), static_cast<int>(num(args, "height", 720)),
                 static_cast<float>(num(args, "scale", 1)));
    result->Success();
  } else if (method == "close") {
    if (texture_id >= 0) {
      stage.on_frame(nullptr, nullptr);
      stage.stop();
      attached = false;
      const int64_t id = texture_id;
      texture_id = -1;
      FlutterDesktopTextureRegistrarUnregisterExternalTexture(registrar, id, nullptr, nullptr);
    }
    result->Success();
  } else {
    result->NotImplemented();
  }
}

}  // namespace

void stage_texture_register(flutter::FlutterEngine* engine) {
  // The texture registrar through a plugin registrar of the app's own.
  registrar = FlutterDesktopRegistrarGetTextureRegistrar(engine->GetRegistrarForPlugin("WetowlStage"));
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel;
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "wetowl/stage", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(on_call);
}
