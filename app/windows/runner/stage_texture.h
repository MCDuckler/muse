// The native stage's picture in a Flutter view, on Windows: the channel
// "wetowl/stage" (open → a texture id, size, close), as linux/runner/stage_texture.cc
// has it. See stage_texture.cpp.
#pragma once

#include <flutter/flutter_engine.h>

void stage_texture_register(flutter::FlutterEngine* engine);
