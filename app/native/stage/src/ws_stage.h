// WetOwl's native stage: the show drawn in OpenGL ES 3 at full resolution, in
// floating point, on a thread and a GL context of its own (see stage.cpp; why:
// ~/.claude/plans/wetowl-show-v2.md, M2).
//
// One stage per process. It draws either
//   - into textures a Flutter view shows (ws_attach_current, from the thread whose
//     GL context the textures must be shared with — Flutter's raster thread, from an
//     FlTextureGL's populate), or
//   - with no window at all (ws_attach_headless: a bench, an offline render).
//
// The scenes are the Flutter stage's own .frag files (app/shaders/show/), read from a
// directory and fitted to GLSL ES on load; a file changed on disk is compiled again
// on the next frame.
#pragma once
#include <stdint.h>

#ifdef _WIN32
#define WS_API __declspec(dllexport)
#else
#define WS_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// The common block every scene reads, in the order of shaders/show/common.glsl:
// uResolution (2, filled in by the stage) then uTime .. uBarIndex.
#define WS_COMMON 37

// Where the scene shaders are. Call before attaching.
WS_API void ws_shaders(const char* dir);

// Draws into textures shared with the EGL context current on the calling thread.
// Returns 0, or an error number (ws_error says what).
WS_API int ws_attach_current(void);
// Draws with no window, on EGL device `device` (-1: the default display). Returns
// 0 or an error number.
WS_API int ws_attach_headless(int device);
WS_API const char* ws_error(void);
WS_API void ws_stop(void);

// The picture's size in pixels; the working passes are drawn at `scale` of it.
WS_API void ws_size(int width, int height, float scale);
// Frames a second the thread aims at (0: as fast as it can, for a bench).
WS_API void ws_rate(float fps);
// The scene by name (its .frag), and how the stage finishes it.
WS_API void ws_scene(const char* name);
WS_API void ws_post(float trails, float bloom, float vignette, float grain, float tone, float fringe);
// The scene being left and how far across to the one on (1: none), with its knobs
// (uM1..4); null for none.
WS_API void ws_from(const char* name, float k, const float* knobs);
// White over everything (the strobe, the hands' hit), the blackout, and the frame
// held (the particles stop; the shaders' clock does not).
WS_API void ws_flash(float white, float black, int freeze);
// The palette: primary, secondary, accent, RGB 0..1 each.
WS_API void ws_palette(const float* rgb9);
// The particle systems over the scene, by kind, comma-separated ("sparks,dust").
WS_API void ws_particles(const char* kinds);
// The trails' recipe (feedback.frag): decay zoom rotate tint tintR tintG tintB fold
// warp hueTurn shiftX shiftY; n < 12 is the stage's own defaults.
WS_API void ws_trails(const float* recipe, int n);
// The dancers (dance.h), drawn where the scene is "@dance": a mesh (returns its id),
// its skin (RGBA, top row first), a texture by name (the glyphs), and the frame's
// list of commands (lib/src/ui/show/show_dance_surface.dart writes them).
WS_API int ws_dance_mesh(int positions, const float* pos, const float* nrm, const uint8_t* bones, const uint8_t* weights,
                         int corners, const float* uv, const uint16_t* src, int tris, const uint16_t* idx);
WS_API void ws_dance_skin(int mesh, int width, int height, const uint8_t* rgba);
WS_API void ws_dance_texture(const char* name, int width, int height, const uint8_t* rgba, int flipRows);
WS_API void ws_dance_frame(const float* commands, int n);
// The ground under the figure (lib/src/state/show/show_rig.dart's RigGround): its
// kind (0 black 1 wash 2 milk 3 camera 4 field 5 cover 6 pulse), a field's shader by
// name (else null), how much of it, and uM1..4 for the field. MilkDrop must be open
// for a milk ground.
WS_API void ws_ground(int kind, const char* field, float dim, const float* knobs4);
// The blend (RigBlend; shaders/show/under.frag): the backdrop's way (GroundMode
// 0..11), the figure's (0 over, 1 the same, 2 as the figure asks: over for the plain
// dancers, the same for the rest), which pixels are the figure (0 the alpha 254/255
// band, 1 the alpha — the dancers' frame carries its coverage), and how much of the
// blend (0: none drawn).
WS_API void ws_blend(int ground, int figure, int coverage, float strength);
// The common block for the next frame: values 2.. of it (uTime on), n of them.
WS_API void ws_inputs(const float* values, int n);

// The newest finished frame, for the context the stage was attached to: its texture
// name and size. Waits (on the GPU, not here) for it to be finished. 0 when there is
// none yet.
WS_API uint32_t ws_latest(int* width, int* height);
// Called (on the stage's thread) each time a frame is finished.
WS_API void ws_on_frame(void (*callback)(void* user), void* user);

// MilkDrop in the stage's context: the helper's commands (native/milk/wetowl-milk.cpp
// lists them), applied on the stage's thread before its next frame. "open W H FPS
// [TEXTURES]" first. A scene samples it as uMilk.
WS_API void ws_milk(const char* line, const uint8_t* payload, int length);
// What MilkDrop said since the last ask ("preset ok NAME", "preset failed NAME: WHY"),
// a line each; the number of bytes written (0: nothing).
WS_API int ws_milk_said(char* out, int capacity);

// How it is going: frames drawn, frames a second over the last second, the
// milliseconds a frame took on the thread (with a glFinish in bench mode), the
// working size.
typedef struct {
  int64_t frames;
  float fps, frame_ms, worst_ms;
  int32_t width, height, work_width, work_height;
  int32_t float_targets;   // 1: RGBA16F working passes, 0: fell back to RGBA8
  float auto_scale;        // the share of the asked working size the thread chose
} ws_stats_t;
WS_API void ws_stats(ws_stats_t* out);

// Bench: draws n frames now, on this thread, headless only; the time each took is
// in ws_stats. The last frame's pixels into rgba (width*height*4) if not null.
WS_API int ws_bench(int frames, uint8_t* rgba);

#ifdef __cplusplus
}
#endif
