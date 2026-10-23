// A picture the stage draws into: a texture, its framebuffer, and a depth buffer
// under it where one is asked for. Shared by the stage (stage.cpp) and its own
// passes (fx.h).
#pragma once
#include <GLES3/gl3.h>

namespace ws {

struct Target {
  GLuint tex = 0, fbo = 0, depth = 0;
  int w = 0, h = 0, depthW = 0, depthH = 0;
  GLenum internal = 0;
  // A depth buffer under it (the dancers'), made when first asked for.
  void withDepth() {
    if (depth && depthW == w && depthH == h) return;
    if (!depth) glGenRenderbuffers(1, &depth);
    glBindRenderbuffer(GL_RENDERBUFFER, depth);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, w, h);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depth);
    depthW = w; depthH = h;
  }
  void make(int width, int height, GLenum fmt) {
    if (tex && w == width && h == height && internal == fmt) return;
    drop();
    w = width; h = height; internal = fmt;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexStorage2D(GL_TEXTURE_2D, 1, fmt, w, h);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
  }
  void drop() {
    if (fbo) glDeleteFramebuffers(1, &fbo);
    if (tex) glDeleteTextures(1, &tex);
    if (depth) glDeleteRenderbuffers(1, &depth);
    tex = fbo = depth = 0; w = h = depthW = depthH = 0;
  }
  void bind() const {
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glViewport(0, 0, w, h);
  }
};

}  // namespace ws
