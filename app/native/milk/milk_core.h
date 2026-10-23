// MilkDrop's core, shared by the two places it is drawn: the wetowl-milk helper
// (wetowl-milk.cpp: its own process, frames back over a pipe) and the native stage
// (native/stage/: in the stage's own GL context, a texture the scene samples).
//
// projectM made and set up as the booth wants it, a framebuffer of its own to draw
// into, and the commands — one line each, a payload where the command has one; see
// wetowl-milk.cpp for the list. The includer brings projectM's header and the GL
// functions (desktop GL for the helper, GLES 3 for the stage); everything here is in
// both.
#pragma once

#include <cstdint>
#include <cstdlib>
#include <functional>
#include <sstream>
#include <string>
#include <vector>

namespace milk {

inline std::string presetName(const std::string& path) {
    auto slash = path.find_last_of('/');
    auto name = slash == std::string::npos ? path : path.substr(slash + 1);
    if (name.size() > 5 && name.compare(name.size() - 5, 5, ".milk") == 0) name.resize(name.size() - 5);
    return name;
}

// Whether a command line carries a payload, and how many bytes of it.
inline size_t payloadOf(const std::string& line) {
    std::istringstream in(line);
    std::string word;
    size_t n = 0;
    in >> word;
    if (word != "data" && word != "data-soft" && word != "pcm") return 0;
    in >> n;
    return word == "pcm" ? n * 2 : n;
}

struct Core {
    projectm_handle pm = nullptr;
    int width = 0, height = 0;
    GLuint fbo = 0, tex = 0;
    std::string wanted;  // the preset last asked for, for the failure line

    // What it has to say ("preset ok NAME", "preset failed NAME: WHY").
    std::function<void(const std::string&)> say = [](const std::string&) {};
    // A new size (after the framebuffer is remade), a new rate: for the owner's own.
    std::function<bool(int, int)> onSize = [](int, int) { return true; };
    std::function<void(int)> onFps = [](int) {};

    bool open(int w, int h, int fps, const std::string& textures) {
        pm = projectm_create();
        if (!pm) return false;
        width = w;
        height = h;
        projectm_set_window_size(pm, w, h);
        projectm_set_fps(pm, fps);
        meshFor(w);
        projectm_set_aspect_correction(pm, true);
        // The booth decides when presets change; projectM's own clock never does.
        projectm_set_preset_duration(pm, 1e9);
        projectm_set_hard_cut_enabled(pm, false);
        projectm_set_soft_cut_duration(pm, 1.2);
        projectm_set_preset_switch_failed_event_callback(pm, &Core::switchFailed, this);
        if (!textures.empty()) {
            const char* paths[] = {textures.c_str()};
            projectm_set_texture_search_paths(pm, paths, 1);
        }
        makeFbo();
        return true;
    }

    // The warp's mesh: finer on a bigger picture, where 48 by 36 cells show their
    // straight edges.
    void meshFor(int w) {
        if (w >= 1600) projectm_set_mesh_size(pm, 96, 72);
        else if (w >= 1200) projectm_set_mesh_size(pm, 64, 48);
        else projectm_set_mesh_size(pm, 48, 36);
    }

    void close() {
        if (pm) projectm_destroy(pm);
        pm = nullptr;
        if (fbo) glDeleteFramebuffers(1, &fbo);
        if (tex) glDeleteTextures(1, &tex);
        fbo = tex = 0;
    }

    // The frame is drawn into a framebuffer of its own, not the context's default
    // one: a window that is never shown owns no pixels on Windows (what is read back
    // is whatever was there), a Mac context without a drawable has none, and the
    // stage's context has no surface at all.
    void makeFbo() {
        if (fbo) {
            glDeleteFramebuffers(1, &fbo);
            glDeleteTextures(1, &tex);
        }
        glGenTextures(1, &tex);
        glBindTexture(GL_TEXTURE_2D, tex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glBindTexture(GL_TEXTURE_2D, 0);
        glGenFramebuffers(1, &fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) say("gl: the framebuffer is not complete");
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        projectm_opengl_set_target_framebuffer(pm, fbo);
    }

    // One command. False for "quit" (or a size that could not be had).
    bool command(const std::string& line, const std::vector<uint8_t>& payload) {
        std::istringstream in(line);
        std::string word;
        in >> word;
        if (word == "quit") {
            return false;
        } else if (word == "size") {
            int w = 0, h = 0;
            in >> w >> h;
            if (w > 0 && h > 0 && (w != width || h != height)) {
                width = w;
                height = h;
                projectm_set_window_size(pm, w, h);
                meshFor(w);
                makeFbo();
                if (!onSize(w, h)) return false;
            }
        } else if (word == "fps") {
            int f = 0;
            in >> f;
            if (f > 0) {
                projectm_set_fps(pm, f);
                onFps(f);
            }
        } else if (word == "preset" || word == "preset-soft") {
            std::string path;
            std::getline(in, path);
            if (!path.empty() && path[0] == ' ') path.erase(0, 1);
            wanted = path;
            projectm_load_preset_file(pm, path.c_str(), word == "preset-soft");
            say("preset ok " + presetName(path));
        } else if (word == "data" || word == "data-soft") {
            std::string text(payload.begin(), payload.end());
            wanted = "(edited)";
            projectm_load_preset_data(pm, text.c_str(), word == "data-soft");
            say("preset ok (edited)");
        } else if (word == "blend") {
            // How long the next soft change blends, in seconds.
            double secs = 0;
            in >> secs;
            if (secs > 0) projectm_set_soft_cut_duration(pm, secs);
        } else if (word == "lock") {
            int v = 0;
            in >> v;
            projectm_set_preset_locked(pm, v != 0);
        } else if (word == "var") {
            std::string name;
            float value = 0;
            in >> name >> value;
            projectm_set_custom_variable(pm, name.c_str(), value);
        } else if (word == "vars") {
            std::string pair;
            while (in >> pair) {
                auto eq = pair.find('=');
                if (eq == std::string::npos) continue;
                projectm_set_custom_variable(pm, pair.substr(0, eq).c_str(), std::strtof(pair.c_str() + eq + 1, nullptr));
            }
        } else if (word == "pcm") {
            size_t n = payload.size() / 2;
            if (n > 0) {
                projectm_pcm_add_int16(pm, reinterpret_cast<const int16_t*>(payload.data()), static_cast<unsigned int>(n),
                                       PROJECTM_MONO);
            }
        } else if (word == "audio") {
            std::string first;
            in >> first;
            if (first == "off") {
                projectm_clear_audio_levels(pm);
            } else {
                float lv[6] = {1, 1, 1, 1, 1, 1};
                lv[0] = std::strtof(first.c_str(), nullptr);
                for (int i = 1; i < 6; i++) in >> lv[i];
                projectm_set_audio_levels(pm, lv[0], lv[1], lv[2], lv[3], lv[4], lv[5]);
            }
        } else if (word == "beat") {
            float s = 1;
            in >> s;
            projectm_set_beat_sensitivity(pm, s);
        } else if (word == "textures") {
            std::string dir;
            std::getline(in, dir);
            if (!dir.empty() && dir[0] == ' ') dir.erase(0, 1);
            const char* paths[] = {dir.c_str()};
            projectm_set_texture_search_paths(pm, paths, 1);
        }
        return true;
    }

    // A frame, into the framebuffer.
    void render() {
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glViewport(0, 0, width, height);
        projectm_opengl_render_frame(pm);
    }

    static void switchFailed(const char* filename, const char* message, void* user) {
        auto* self = static_cast<Core*>(user);
        self->say(std::string("preset failed ") + presetName(filename ? filename : self->wanted) + ": " + (message ? message : "?"));
    }
};

}  // namespace milk
