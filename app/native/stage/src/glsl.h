// The Flutter stage's shaders (app/shaders/show/*.frag), read and fitted to GLSL ES
// 3.00 for the native stage. Flutter compiles them from GLSL 4.60 with its runtime
// effect header; the differences that matter are few:
//
//   #version 460 core                    →  #version 300 es, and the precisions
//   #include <flutter/runtime_effect.glsl>  gone
//   FlutterFragCoord()                   →  the pixel from the top, as Flutter has it
//                                           (GL counts from the bottom)
//   texture(s, uv)                       →  the image the way up Flutter hands it (a
//                                           GL texture holds its bottom row first)
//
// Everything else — the uniforms by name, the samplers in their order, `out vec4
// fragColor` — is GLSL ES as it stands. A file changed on disk is compiled again.
#pragma once
#include <GLES3/gl3.h>

#include <sys/stat.h>

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <iterator>
#include <cstdio>
#include <fstream>
#include <map>
#include <memory>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

namespace ws::glsl {

inline GLuint compile(GLenum kind, const std::string& src, std::string& err) {
  GLuint s = glCreateShader(kind);
  const char* p = src.c_str();
  glShaderSource(s, 1, &p, nullptr);
  glCompileShader(s);
  GLint ok = 0;
  glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[4096];
    glGetShaderInfoLog(s, sizeof log, nullptr, log);
    err = log;
    glDeleteShader(s);
    return 0;
  }
  return s;
}

inline GLuint link(const std::string& vert, const std::string& frag, std::string& err) {
  // A slow one said, with its first line: on Windows ANGLE hands GLSL to Direct3D's
  // own compiler, which can take seconds over a shader, every other GL context in
  // the process (Flutter's too) waiting on it.
  const auto began = std::chrono::steady_clock::now();
  struct Said {
    const std::string& frag;
    std::chrono::steady_clock::time_point began;
    ~Said() {
      const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - began).count();
      if (ms > 250) {
        const auto nl = frag.find('\n', frag.find("void main") == std::string::npos ? 0 : frag.find("void main") > 400 ? frag.find("void main") - 400 : 0);
        std::fprintf(stderr, "stage: a shader took %lld ms to compile (%zu bytes, near: %.60s)\n", (long long)ms, frag.size(),
                     frag.c_str() + (nl == std::string::npos ? 0 : nl + 1));
      }
    }
  } said{frag, began};
  GLuint v = compile(GL_VERTEX_SHADER, vert, err);
  if (!v) return 0;
  GLuint f = compile(GL_FRAGMENT_SHADER, frag, err);
  if (!f) { glDeleteShader(v); return 0; }
  GLuint p = glCreateProgram();
  glAttachShader(p, v);
  glAttachShader(p, f);
  glLinkProgram(p);
  glDeleteShader(v);
  glDeleteShader(f);
  GLint ok = 0;
  glGetProgramiv(p, GL_LINK_STATUS, &ok);
  if (!ok) {
    char log[4096];
    glGetProgramInfoLog(p, sizeof log, nullptr, log);
    err = log;
    glDeleteProgram(p);
    return 0;
  }
  return p;
}

// A Flutter .frag as GLSL ES 3.00.
inline std::string fit(const std::string& src) {
  std::string out;
  out.reserve(src.size() + 512);
  out +=
      "#version 300 es\n"
      "precision highp float;\n"
      "precision highp int;\n"
      "precision highp sampler2D;\n"
      "uniform float wsHeight;\n"
      "vec4 FlutterFragCoord() { return vec4(gl_FragCoord.x, wsHeight - gl_FragCoord.y, gl_FragCoord.zw); }\n"
      // Flutter hands a shader its images top row first; a GL texture holds its bottom
      // row first. Every sampling turned over, so a scene reads its images (MilkDrop's,
      // the trails' last frame) the way up it was written for.
      "vec4 wsTexture(sampler2D s, vec2 uv) { return texture(s, vec2(uv.x, 1.0 - uv.y)); }\n"
      "#define texture wsTexture\n";
  std::istringstream in(src);
  std::string line;
  int n = 0;
  while (std::getline(in, line)) {
    n++;
    if (line.rfind("#version", 0) == 0) { out += "\n"; continue; }
    if (line.find("#include <flutter/runtime_effect.glsl>") != std::string::npos) { out += "\n"; continue; }
    out += line;
    out += "\n";
  }
  return out;
}

static const char* kVertex = R"(#version 300 es
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
)";

struct Program {
  GLuint id = 0;
  std::map<std::string, GLint> locs;
  std::vector<std::string> samplers;   // in the order the file declares them
  // The float uniforms (float, vec2, vec3, vec4; no arrays) in the order the file
  // declares them, each with its count of floats: Flutter's setFloat(i) numbers a
  // shader's floats this way, so a sim's frame can be handed over as one list.
  std::vector<std::pair<std::string, int>> floats;
  GLint loc(const char* name) const {
    auto it = locs.find(name);
    return it == locs.end() ? -1 : it->second;
  }
};

// The program's floats from `v` in the file's order, as Flutter's setFloat(i) would:
// n floats; the ones past n stay as they are.
inline void setFloats(const Program& p, const float* v, int n) {
  int at = 0;
  for (const auto& [name, comps] : p.floats) {
    if (at + comps > n) break;
    const GLint loc = p.loc(name.c_str());
    if (loc >= 0) {
      switch (comps) {
        case 1: glUniform1fv(loc, 1, v + at); break;
        case 2: glUniform2fv(loc, 1, v + at); break;
        case 3: glUniform3fv(loc, 1, v + at); break;
        default: glUniform4fv(loc, 1, v + at); break;
      }
    }
    at += comps;
  }
}

// KHR_parallel_shader_compile (ANGLE has it): a program's compile and link go on in
// the background, and this says when they are done.
#ifndef GL_COMPLETION_STATUS_KHR
#define GL_COMPLETION_STATUS_KHR 0x91B1
#endif

// A key that is the same from run to run (std::hash need not be).
inline uint64_t fnv(const std::string& s, uint64_t h = 1469598103934665603ull) {
  for (unsigned char c : s) {
    h ^= c;
    h *= 1099511628211ull;
  }
  return h;
}

class Programs {
 public:
  std::string dir;
  // Where compiled programs are kept between runs ("" none), and what of this GPU
  // goes into their key (a binary is the driver's, and good for no other).
  std::string cacheDir, renderer;
  // Compiles in the background (KHR_parallel_shader_compile): a scene whose program
  // is not ready yet is not drawn until it is (stage.cpp draws the one before), and
  // the thread goes on drawing. Without it a compile holds the thread, as it always
  // did: under ANGLE on Windows seven seconds for the biggest scene, the stage given
  // up for drawing nothing, and the app frozen while it was closed.
  bool parallel = false;

  // The scene's program, compiled again if its file changed (checked every half
  // second); the last good one while a new one does not compile or is being compiled;
  // null if none ever did (or the first is not ready yet: waiting() says so).
  const Program* get(const std::string& name) {
    auto& e = entries_[name];
    finish(name, e);
    const auto now = std::chrono::steady_clock::now();
    if (e.checked.time_since_epoch().count() != 0 && now - e.checked < std::chrono::milliseconds(500)) return e.program.get();
    e.checked = now;
    if (e.pending) return e.program.get();
    const std::string path = dir + "/" + name + ".frag";
    struct stat st{};
    if (stat(path.c_str(), &st) != 0) {
      if (!e.complained) { std::fprintf(stderr, "stage: no %s\n", path.c_str()); e.complained = true; }
      return e.program.get();
    }
    if (e.program && st.st_mtime == e.mtime) return e.program.get();
    e.mtime = st.st_mtime;
    std::ifstream f(path);
    std::stringstream ss;
    ss << f.rdbuf();
    start(name, e, ss.str());
    finish(name, e);
    return e.program.get();
  }

  // Being compiled still, with nothing older to draw meanwhile.
  bool waiting(const std::string& name) {
    auto it = entries_.find(name);
    return it != entries_.end() && it->second.pending && !it->second.program;
  }

  // The program [name] has now, without looking at its file.
  const Program* had(const std::string& name) {
    auto it = entries_.find(name);
    return it == entries_.end() ? nullptr : it->second.program.get();
  }

  // Every compile in the background looked at once: the ones done taken in (and kept
  // on disk). Each frame; a query a program, nothing waited for.
  void poll() {
    for (auto& [name, e] : entries_) finish(name, e);
  }

  // Every scene's and pass's program started at once (in the background where the
  // GPU can, or from the disk where it was kept), so no scene waits for its compile
  // when the director first puts it on: at a drop, mostly.
  void prewarm() {
    for (const char* sub : {"", "sim/"}) {
      std::error_code ec;
      const std::filesystem::path d = std::filesystem::path(dir) / sub;
      for (const auto& f : std::filesystem::directory_iterator(d, ec)) {
        if (!f.is_regular_file() || f.path().extension() != ".frag") continue;
        const std::string name = std::string(sub) + f.path().stem().string();
        if (entries_.count(name)) continue;
        // Where it must wait, only what is on the disk already: a compile here would
        // be the stall this is for.
        if (!parallel && !cached(name)) continue;
        get(name);
      }
    }
  }

  // Every program let go (its context is going); each is compiled again when next
  // asked for.
  void clear() {
    for (auto& [name, e] : entries_) {
      if (e.program) glDeleteProgram(e.program->id);
      if (e.pending) drop(e);
    }
    entries_.clear();
  }

 private:
  struct Entry {
    std::unique_ptr<Program> program;
    time_t mtime = 0;
    std::chrono::steady_clock::time_point checked{};
    bool complained = false;
    // A compile under way: its program, its shaders, its source, its key, when.
    bool pending = false;
    GLuint prog = 0, vs = 0, fs = 0;
    std::string src;
    uint64_t key = 0;
    std::chrono::steady_clock::time_point began{};
  };
  std::map<std::string, Entry> entries_;

  uint64_t keyOf(const std::string& fitted) const { return fnv(renderer + "\n" + kVertex + "\n" + fitted); }

  std::string cachePath(uint64_t key) const {
    char hex[24];
    std::snprintf(hex, sizeof hex, "%016llx", (unsigned long long)key);
    return cacheDir + "/" + hex + ".bin";
  }

  bool cached(const std::string& name) const {
    if (cacheDir.empty()) return false;
    std::ifstream f(dir + "/" + name + ".frag");
    if (!f) return false;
    std::stringstream ss;
    ss << f.rdbuf();
    struct stat st{};
    return stat(cachePath(keyOf(fit(ss.str()))).c_str(), &st) == 0;
  }

  static void drop(Entry& e) {
    if (e.prog) glDeleteProgram(e.prog);
    if (e.vs) glDeleteShader(e.vs);
    if (e.fs) glDeleteShader(e.fs);
    e.prog = e.vs = e.fs = 0;
    e.pending = false;
    e.src.clear();
  }

  // The program from the disk, where it was kept for this GPU and this source; else
  // its compile and link begun (in the background, where the GPU can).
  void start(const std::string& name, Entry& e, const std::string& src) {
    const std::string fitted = fit(src);
    e.src = src;
    e.key = keyOf(fitted);
    e.began = std::chrono::steady_clock::now();
    if (!cacheDir.empty()) {
      std::ifstream f(cachePath(e.key), std::ios::binary);
      if (f) {
        GLenum format = 0;
        f.read(reinterpret_cast<char*>(&format), sizeof format);
        std::vector<char> bin((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        GLuint p = glCreateProgram();
        glProgramBinary(p, format, bin.data(), (GLsizei)bin.size());
        GLint ok = 0;
        glGetProgramiv(p, GL_LINK_STATUS, &ok);
        if (ok) {
          e.prog = p;
          e.pending = true;
          take(name, e, /*kept*/ true);
          return;
        }
        // Another driver, or a binary gone stale: compiled afresh.
        glDeleteProgram(p);
      }
    }
    e.vs = glCreateShader(GL_VERTEX_SHADER);
    e.fs = glCreateShader(GL_FRAGMENT_SHADER);
    const char* v = kVertex;
    const char* fr = fitted.c_str();
    glShaderSource(e.vs, 1, &v, nullptr);
    glShaderSource(e.fs, 1, &fr, nullptr);
    glCompileShader(e.vs);
    glCompileShader(e.fs);
    e.prog = glCreateProgram();
    glAttachShader(e.prog, e.vs);
    glAttachShader(e.prog, e.fs);
    if (!cacheDir.empty()) glProgramParameteri(e.prog, GL_PROGRAM_BINARY_RETRIEVABLE_HINT, GL_TRUE);
    glLinkProgram(e.prog);
    e.pending = true;
  }

  // A compile under way taken in where it is done (at once where there is no
  // background to do it in).
  void finish(const std::string& name, Entry& e) {
    if (!e.pending) return;
    if (parallel) {
      GLint done = 0;
      glGetProgramiv(e.prog, GL_COMPLETION_STATUS_KHR, &done);
      if (!done) return;
    }
    GLint ok = 0;
    glGetProgramiv(e.prog, GL_LINK_STATUS, &ok);
    if (!ok) {
      char log[4096] = {0};
      GLint compiled = 0;
      glGetShaderiv(e.fs, GL_COMPILE_STATUS, &compiled);
      if (!compiled) glGetShaderInfoLog(e.fs, sizeof log, nullptr, log);
      else glGetProgramInfoLog(e.prog, sizeof log, nullptr, log);
      std::fprintf(stderr, "stage: %s does not compile:\n%s\n", name.c_str(), log);
      drop(e);
      return;
    }
    take(name, e, /*kept*/ false);
  }

  // A linked program in: its uniforms and samplers read, kept on the disk for next
  // time (where it was not from there), the old one let go.
  void take(const std::string& name, Entry& e, bool kept) {
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - e.began).count();
    if (!kept && !cacheDir.empty()) {
      GLint len = 0;
      glGetProgramiv(e.prog, GL_PROGRAM_BINARY_LENGTH, &len);
      if (len > 0) {
        std::vector<char> bin((size_t)len);
        GLenum format = 0;
        GLsizei got = 0;
        glGetProgramBinary(e.prog, len, &got, &format, bin.data());
        std::error_code ec;
        std::filesystem::create_directories(cacheDir, ec);
        std::ofstream out(cachePath(e.key), std::ios::binary);
        if (out && got > 0) {
          out.write(reinterpret_cast<const char*>(&format), sizeof format);
          out.write(bin.data(), got);
        }
      }
    }
    auto p = std::make_unique<Program>();
    p->id = e.prog;
    GLint count = 0;
    glGetProgramiv(e.prog, GL_ACTIVE_UNIFORMS, &count);
    for (GLint i = 0; i < count; i++) {
      char nm[128];
      GLint size; GLenum type;
      glGetActiveUniform(e.prog, (GLuint)i, sizeof nm, nullptr, &size, &type, nm);
      p->locs[nm] = glGetUniformLocation(e.prog, nm);
    }
    static const std::regex sampler(R"(uniform\s+sampler2D\s+(\w+)\s*;)");
    for (auto it = std::sregex_iterator(e.src.begin(), e.src.end(), sampler); it != std::sregex_iterator(); ++it) {
      p->samplers.push_back((*it)[1].str());
    }
    static const std::regex floats(R"(uniform\s+(float|vec2|vec3|vec4)\s+(\w+)\s*;)");
    for (auto it = std::sregex_iterator(e.src.begin(), e.src.end(), floats); it != std::sregex_iterator(); ++it) {
      const std::string type = (*it)[1].str();
      p->floats.emplace_back((*it)[2].str(), type == "float" ? 1 : type == "vec2" ? 2 : type == "vec3" ? 3 : 4);
    }
    if (e.vs) glDeleteShader(e.vs);
    if (e.fs) glDeleteShader(e.fs);
    e.vs = e.fs = 0;
    if (e.program) glDeleteProgram(e.program->id);
    e.program = std::move(p);
    e.prog = 0;
    e.pending = false;
    e.src.clear();
    if (kept) std::fprintf(stderr, "stage: %s from the disk (%lld ms)\n", name.c_str(), (long long)ms);
    else std::fprintf(stderr, "stage: %s compiled in %lld ms%s\n", name.c_str(), (long long)ms, parallel ? " (in the background)" : "");
  }
};

}  // namespace ws::glsl
