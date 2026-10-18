// The native stage (native/stage/) in a Flutter view: a texture the stage draws on
// its own thread, shown by a Texture widget (lib/src/ui/show/native_stage.dart).
#pragma once
#include <flutter_linux/flutter_linux.h>

// Answers the "wetowl/stage" channel on the view's messenger: open (→ the texture's
// id, or an error where the stage's library is not here), size, close.
void stage_texture_register(FlPluginRegistry* registry);
