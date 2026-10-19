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

class Programs {
 public:
  std::string dir;

  // The scene's program, compiled again if its file changed (checked every half
  // second); the last good one while a new one does not compile; null if none ever did.
  const Program* get(const std::string& name) {
    auto& e = entries_[name];
    const auto now = std::chrono::steady_clock::now();
    if (e.checked.time_since_epoch().count() != 0 && now - e.checked < std::chrono::milliseconds(500)) return e.program.get();
    e.checked = now;
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
    const std::string src = ss.str();
    std::string err;
    GLuint id = link(kVertex, fit(src), err);
    if (!id) {
      std::fprintf(stderr, "stage: %s does not compile:\n%s\n", name.c_str(), err.c_str());
      return e.program.get();
    }
    auto p = std::make_unique<Program>();
    p->id = id;
    GLint count = 0;
    glGetProgramiv(id, GL_ACTIVE_UNIFORMS, &count);
    for (GLint i = 0; i < count; i++) {
      char nm[128];
      GLint size; GLenum type;
      glGetActiveUniform(id, (GLuint)i, sizeof nm, nullptr, &size, &type, nm);
      p->locs[nm] = glGetUniformLocation(id, nm);
    }
    static const std::regex sampler(R"(uniform\s+sampler2D\s+(\w+)\s*;)");
    for (auto it = std::sregex_iterator(src.begin(), src.end(), sampler); it != std::sregex_iterator(); ++it) {
      p->samplers.push_back((*it)[1].str());
    }
    static const std::regex floats(R"(uniform\s+(float|vec2|vec3|vec4)\s+(\w+)\s*;)");
    for (auto it = std::sregex_iterator(src.begin(), src.end(), floats); it != std::sregex_iterator(); ++it) {
      const std::string type = (*it)[1].str();
      p->floats.emplace_back((*it)[2].str(), type == "float" ? 1 : type == "vec2" ? 2 : type == "vec3" ? 3 : 4);
    }
    if (e.program) glDeleteProgram(e.program->id);
    e.program = std::move(p);
    std::fprintf(stderr, "stage: %s compiled\n", name.c_str());
    return e.program.get();
  }

  // Every program let go (its context is going); each is compiled again when next
  // asked for.
  void clear() {
    for (auto& [name, e] : entries_) if (e.program) glDeleteProgram(e.program->id);
    entries_.clear();
  }

 private:
  struct Entry {
    std::unique_ptr<Program> program;
    time_t mtime = 0;
    std::chrono::steady_clock::time_point checked{};
    bool complained = false;
  };
  std::map<std::string, Entry> entries_;
};

}  // namespace ws::glsl
