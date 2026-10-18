// wetowl-milk: MilkDrop (projectM) rendered offscreen for the booth's show.
//
// The booth starts this as a child, the way it starts ffmpeg for the camera, and
// talks to it over its pipes:
//
//   stdin  — one command a line; a payload, where a command has one, follows its line:
//     size W H              the picture's size (the pbuffer is remade)
//     fps N                 how often a frame is rendered
//     preset PATH           a preset file, hard cut (preset-soft PATH blends to it)
//     data N / data-soft N  a preset as text: N bytes follow
//     lock 0|1              hold the preset (no switching, hard cuts off)
//     var NAME VALUE        one value preset code reads by name (wo_kick, ...)
//     vars N=V N=V ...      several at once
//     pcm N                 N int16 mono samples at 44100 Hz follow (2N bytes)
//     audio B M T BA MA TA  bass/mid/treb and their slow followers, in place of the
//                           FFT's (1 = average, a hit 2..3); "audio off" for the FFT
//     beat S                projectM's beat sensitivity
//     textures DIR          where presets' textures are looked for
//     quit
//   stdout — frames: "MILK" + u32 width + u32 height + u32 sequence, then RGBA
//            bytes, top row first. Only rendered while the parent reads: a full
//            pipe blocks the render, which is the parent saying it is behind.
//            Nothing else: the pipe is kept for the frames alone, and what the
//            libraries print to stdout goes to stderr (see main).
//   stderr — lines: "ready", "preset ok NAME", "preset failed NAME: WHY", "egl ...",
//            and whatever projectM has to say.
//
// Offscreen through EGL, trying the surfaceless platform, then a GBM render node,
// then whatever the default display is (X11, Wayland) — so it draws on a desk
// with no window of its own and on a box with no display at all.
#include <projectM-4/projectM.h>

#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#include <GL/glew.h>
#include <GL/wglew.h>
#include <fcntl.h>
#include <io.h>
#else
#include <EGL/egl.h>
#include <EGL/eglext.h>
#define GL_GLEXT_PROTOTYPES 1
#include <GL/gl.h>
#include <GL/glext.h>
#include <unistd.h>
#endif

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <fcntl.h>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "milk_core.h"

#ifdef _WIN32
// The fast GPU where a laptop has two (NVIDIA Optimus, AMD switchable graphics): the
// drivers read these from the program itself, and without them its OpenGL is the
// integrated chip's, drawing MilkDrop beside the app on the weaker of the two.
extern "C" {
__declspec(dllexport) unsigned long NvOptimusEnablement = 0x00000001;
__declspec(dllexport) int AmdPowerXpressRequestHighPerformance = 1;
}
#endif

namespace {

struct Command {
    std::string line;
    std::vector<uint8_t> payload;
};

std::mutex g_mutex;
std::condition_variable g_wake;
std::deque<Command> g_queue;
std::atomic<bool> g_quit{false};

void say(const std::string& s) {
    std::fputs((s + "\n").c_str(), stderr);
    std::fflush(stderr);
}

// Reads stdin whole lines (and payloads) on its own thread, so the render loop
// never waits on the pipe.
#ifdef _WIN32
long readIn(void* buf, size_t n) { return _read(0, buf, static_cast<unsigned int>(n)); }
#else
long readIn(void* buf, size_t n) { return static_cast<long>(read(STDIN_FILENO, buf, n)); }
#endif

// Stdin read in chunks (a byte a call is a system call a byte, which on Windows
// is most of a core at sixty lines a second), handed out as lines and payloads.
struct Reader {
    std::vector<uint8_t> buf;
    size_t at = 0, end = 0;

    bool fill() {
        if (at > 0 && at == end) at = end = 0;
        if (end == buf.size()) {
            if (at > 0) {
                std::memmove(buf.data(), buf.data() + at, end - at);
                end -= at;
                at = 0;
            } else {
                buf.resize(buf.empty() ? 65536 : buf.size() * 2);
            }
        }
        long r = readIn(buf.data() + end, buf.size() - end);
        if (r <= 0) return false;
        end += static_cast<size_t>(r);
        return true;
    }

    bool line(std::string& out) {
        while (true) {
            for (size_t i = at; i < end; i++) {
                if (buf[i] == '\n') {
                    out.assign(reinterpret_cast<const char*>(buf.data() + at), i - at);
                    at = i + 1;
                    return true;
                }
            }
            if (!fill()) return false;
        }
    }

    bool exact(std::vector<uint8_t>& out, size_t n) {
        out.resize(n);
        size_t got = 0;
        while (got < n) {
            if (at == end && !fill()) return false;
            size_t take = std::min(n - got, end - at);
            std::memcpy(out.data() + got, buf.data() + at, take);
            at += take;
            got += take;
        }
        return true;
    }
};

void readerThread() {
    Reader reader;
    reader.buf.resize(65536);
    std::string line;
    while (reader.line(line)) {
        Command cmd;
        cmd.line = line;
        std::istringstream in(cmd.line);
        std::string word;
        in >> word;
        if (word == "data" || word == "data-soft" || word == "pcm") {
            size_t n = 0;
            in >> n;
            size_t bytes = word == "pcm" ? n * 2 : n;
            if (!reader.exact(cmd.payload, bytes)) break;
        }
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            // PCM is the one thing that piles up: when the render is behind, only
            // the newest audio matters — but every chunk is still added, so the
            // waveform never has a hole; it is the commands that are kept short.
            g_queue.push_back(std::move(cmd));
        }
        g_wake.notify_one();
        if (word == "quit") break;
    }
    g_quit = true;
    g_wake.notify_one();
}

#ifdef _WIN32
// Windows: a window that is never shown, for its OpenGL context and its default
// framebuffer (which projectM draws into). Resized with the picture.
struct Egl {
    HWND window = nullptr;
    HDC dc = nullptr;
    HGLRC context = nullptr;
    int width = 0, height = 0;
    std::string platform = "wgl";

    bool open() {
        WNDCLASSA wc = {};
        wc.style = CS_OWNDC;
        wc.lpfnWndProc = DefWindowProcA;
        wc.hInstance = GetModuleHandleA(nullptr);
        wc.lpszClassName = "wetowl-milk";
        RegisterClassA(&wc);
        window = CreateWindowExA(0, "wetowl-milk", "wetowl-milk", WS_POPUP, 0, 0, 64, 64, nullptr, nullptr, wc.hInstance, nullptr);
        if (!window) {
            say("wgl: no window");
            return false;
        }
        dc = GetDC(window);
        PIXELFORMATDESCRIPTOR pfd = {};
        pfd.nSize = sizeof pfd;
        pfd.nVersion = 1;
        pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL;
        pfd.iPixelType = PFD_TYPE_RGBA;
        pfd.cColorBits = 32;
        pfd.cAlphaBits = 8;
        int pf = ChoosePixelFormat(dc, &pfd);
        if (!pf || !SetPixelFormat(dc, pf, &pfd)) {
            say("wgl: no pixel format");
            return false;
        }
        // An old-style context first, to reach the function that makes a new one.
        HGLRC old = wglCreateContext(dc);
        if (!old || !wglMakeCurrent(dc, old)) {
            say("wgl: no context");
            return false;
        }
        glewExperimental = GL_TRUE;
        if (glewInit() != GLEW_OK) {
            say("wgl: glew failed");
            return false;
        }
        if (wglewIsSupported("WGL_ARB_create_context")) {
            const int attribs[] = {
                WGL_CONTEXT_MAJOR_VERSION_ARB, 3,
                WGL_CONTEXT_MINOR_VERSION_ARB, 3,
                WGL_CONTEXT_PROFILE_MASK_ARB, WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
                0};
            context = wglCreateContextAttribsARB(dc, nullptr, attribs);
        }
        if (!context) context = old; else {
            wglMakeCurrent(nullptr, nullptr);
            wglDeleteContext(old);
            wglMakeCurrent(dc, context);
            glewInit();
        }
        return true;
    }

    bool resize(int w, int h) {
        SetWindowPos(window, nullptr, 0, 0, w, h, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_HIDEWINDOW);
        width = w;
        height = h;
        return true;
    }
};
#else
struct Egl {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLConfig config = nullptr;
    int width = 0, height = 0;
    std::string platform;

    bool tryDisplay(EGLDisplay d, const char* name) {
        if (d == EGL_NO_DISPLAY) return false;
        EGLint major, minor;
        if (!eglInitialize(d, &major, &minor)) return false;
        display = d;
        platform = name;
        return true;
    }

    bool open() {
        auto getPlatformDisplay = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
            eglGetProcAddress("eglGetPlatformDisplayEXT"));
        const char* exts = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
        std::string clientExts = exts ? exts : "";
        bool ok = false;
#ifdef EGL_PLATFORM_SURFACELESS_MESA
        if (!ok && getPlatformDisplay && clientExts.find("EGL_MESA_platform_surfaceless") != std::string::npos) {
            ok = tryDisplay(getPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, nullptr), "surfaceless");
        }
#endif
        if (!ok && getPlatformDisplay && clientExts.find("EGL_EXT_platform_device") != std::string::npos) {
            auto queryDevices = reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(eglGetProcAddress("eglQueryDevicesEXT"));
            if (queryDevices) {
                EGLDeviceEXT devices[8];
                EGLint n = 0;
                if (queryDevices(8, devices, &n) && n > 0) {
                    for (int i = 0; i < n && !ok; i++) {
                        ok = tryDisplay(getPlatformDisplay(EGL_PLATFORM_DEVICE_EXT, devices[i], nullptr), "device");
                    }
                }
            }
        }
        if (!ok) ok = tryDisplay(eglGetDisplay(EGL_DEFAULT_DISPLAY), "default");
        if (!ok) {
            say("egl: no display could be opened");
            return false;
        }
        if (!eglBindAPI(EGL_OPENGL_API)) {
            say("egl: no OpenGL API");
            return false;
        }
        const EGLint attribs[] = {
            EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
            EGL_DEPTH_SIZE, 0,
            EGL_NONE};
        EGLint n = 0;
        if (!eglChooseConfig(display, attribs, &config, 1, &n) || n == 0) {
            say("egl: no pbuffer config");
            return false;
        }
        const EGLint ctxAttribs[] = {
            EGL_CONTEXT_MAJOR_VERSION, 3,
            EGL_CONTEXT_MINOR_VERSION, 3,
            EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
            EGL_NONE};
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, ctxAttribs);
        if (context == EGL_NO_CONTEXT) {
            say("egl: no OpenGL 3.3 core context");
            return false;
        }
        return true;
    }

    bool resize(int w, int h) {
        if (surface != EGL_NO_SURFACE) {
            eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            eglDestroySurface(display, surface);
            surface = EGL_NO_SURFACE;
        }
        const EGLint attribs[] = {EGL_WIDTH, w, EGL_HEIGHT, h, EGL_NONE};
        surface = eglCreatePbufferSurface(display, config, attribs);
        if (surface == EGL_NO_SURFACE) {
            say("egl: no pbuffer of " + std::to_string(w) + "x" + std::to_string(h));
            return false;
        }
        if (!eglMakeCurrent(display, surface, surface, context)) {
            say("egl: could not make the context current");
            return false;
        }
        width = w;
        height = h;
        return true;
    }
};

#endif

}  // namespace

int main(int argc, char** argv) {
    int width = 960, height = 540, fps = 60;
    std::string textures;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--size" && i + 1 < argc) {
            std::sscanf(argv[++i], "%dx%d", &width, &height);
        } else if (a == "--fps" && i + 1 < argc) {
            fps = std::atoi(argv[++i]);
        } else if (a == "--textures" && i + 1 < argc) {
            textures = argv[++i];
        }
    }

    // The frames get the pipe to themselves, before anything can print: projectM's
    // shader translator writes its complaints about a preset with printf, and on
    // stdout they landed in the middle of a frame — the parent, out of step, ended
    // the helper and started it again, on the same preset, every second or two.
    // The frames go out on a copy of stdout; stdout itself is stderr from here on.
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    const int framesFd = _dup(_fileno(stdout));
    _dup2(_fileno(stderr), _fileno(stdout));
    SetStdHandle(STD_OUTPUT_HANDLE, GetStdHandle(STD_ERROR_HANDLE));
    _setmode(framesFd, _O_BINARY);
    FILE* frames = _fdopen(framesFd, "wb");
#else
    const int framesFd = dup(STDOUT_FILENO);
    dup2(STDERR_FILENO, STDOUT_FILENO);
    FILE* frames = fdopen(framesFd, "wb");
#endif
    if (!frames) {
        say("frames: no pipe");
        return 2;
    }
    std::setvbuf(stdout, nullptr, _IONBF, 0);  // the complaints in the log as they come
    Egl egl;
    if (!egl.open() || !egl.resize(width, height)) return 2;
    say("egl " + egl.platform + " " + reinterpret_cast<const char*>(glGetString(GL_RENDERER)));

    milk::Core core;
    core.say = say;
    if (!core.open(width, height, fps, textures)) {
        say("projectm: could not be created");
        return 3;
    }

    std::thread reader(readerThread);
    reader.detach();
    say("ready");

    // Two pixel buffers: the frame just drawn is read back while the next draws.
    GLuint pbo[2] = {0, 0};
    glGenBuffers(2, pbo);
    auto allocPbo = [&]() {
        for (auto b : pbo) {
            glBindBuffer(GL_PIXEL_PACK_BUFFER, b);
            glBufferData(GL_PIXEL_PACK_BUFFER, static_cast<GLsizeiptr>(width) * height * 4, nullptr, GL_STREAM_READ);
        }
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    };
    allocPbo();
    int pending = -1;  // the pbo index with a readback in flight, or -1
    uint32_t seq = 0;
    std::vector<uint8_t> flipped(static_cast<size_t>(width) * height * 4);

    auto frameTime = std::chrono::microseconds(1000000 / (fps > 0 ? fps : 60));
    auto next = std::chrono::steady_clock::now();
    core.onSize = [&](int w, int h) {
        width = w;
        height = h;
        if (!egl.resize(w, h)) return false;
        allocPbo();
        pending = -1;
        flipped.resize(static_cast<size_t>(w) * h * 4);
        return true;
    };
    core.onFps = [&](int f) { frameTime = std::chrono::microseconds(1000000 / f); };

    while (!g_quit) {
        // Everything that arrived since the last frame.
        std::deque<Command> batch;
        {
            std::unique_lock<std::mutex> lock(g_mutex);
            g_wake.wait_until(lock, next, [] { return !g_queue.empty() || g_quit; });
            batch.swap(g_queue);
        }
        for (auto& cmd : batch) {
            if (!core.command(cmd.line, cmd.payload)) {
                g_quit = true;
                break;
            }
        }
        if (g_quit) break;
        auto now = std::chrono::steady_clock::now();
        if (now < next) continue;
        next += frameTime;
        if (next < now - frameTime * 4) next = now;  // fell behind: do not chase

        // Draw, and ask for this frame's pixels; take the frame before's.
        core.render();
        int mine = (pending + 1) & 1;
        glBindFramebuffer(GL_READ_FRAMEBUFFER, core.fbo);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo[mine]);
        glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        if (pending >= 0) {
            glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo[pending]);
            auto* src = static_cast<const uint8_t*>(glMapBuffer(GL_PIXEL_PACK_BUFFER, GL_READ_ONLY));
            if (src) {
                // GL reads bottom row first; the parent wants the top.
                const size_t row = static_cast<size_t>(width) * 4;
                for (int y = 0; y < height; y++) {
                    std::memcpy(flipped.data() + static_cast<size_t>(y) * row, src + static_cast<size_t>(height - 1 - y) * row, row);
                }
                glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
                uint32_t header[4] = {0x4b4c494d /* "MILK" */, static_cast<uint32_t>(width), static_cast<uint32_t>(height), seq++};
                if (std::fwrite(header, 1, sizeof header, frames) != sizeof header ||
                    std::fwrite(flipped.data(), 1, flipped.size(), frames) != flipped.size()) {
                    break;  // the parent is gone
                }
                std::fflush(frames);
            }
        }
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        pending = mine;
    }

    core.close();
    return 0;
}
