// Particles over a scene, the Flutter stage's (lib/src/ui/show/show_particles.dart)
// moved here: a few hundred soft points of light, moved on the stage's thread and
// drawn in one instanced call, added to the scene's light before the trails and the
// bloom — so they leave trails and glow like everything else.
//
// The same four kinds and rules: sparks burst from the middle on the kick and fall
// away; dust drifts up slowly and twinkles; rise climbs faster as a build rises; rain
// falls with the top end. In the working picture's pixels.
#pragma once
#include <GLES3/gl3.h>

#include <cmath>
#include <random>
#include <string>
#include <vector>

namespace ws {

struct ParticleInputs {
  float kick, energy, build, dropNear, high;
  float primary[3], accent[3];
  float time;
};

class Particles {
 public:
  explicit Particles(std::string kind) : kind_(std::move(kind)), rng_(11) {}
  const std::string& kind() const { return kind_; }

  void step(const ParticleInputs& in, double dt, int w, int h) {
    if (dt <= 0 || dt > 0.25) dt = 1.0 / 60;
    const double kick = in.kick, energy = in.energy;
    if (kind_ == "sparks") {
      if (kick > 0.45 && kick > kickWas_ + 0.2) {
        const int n = (int)std::lround(14 + 50 * kick * (0.5 + 0.5 * energy));
        for (int i = 0; i < n && (int)ps_.size() < kMost; i++) {
          const double a = u() * M_PI * 2, sp = (0.12 + 0.5 * u()) * h * (0.6 + kick);
          P p;
          p.x = w / 2.0 + (u() - 0.5) * h * 0.04;
          p.y = h / 2.0 + (u() - 0.5) * h * 0.04;
          p.vx = std::cos(a) * sp; p.vy = std::sin(a) * sp;
          p.life = 0.5 + u() * 0.9; p.size = (0.5 + u()) * h * 0.012; p.seed = u();
          ps_.push_back(p);
        }
      }
      kickWas_ = kick;
    } else if (kind_ == "dust") {
      const int want = 90 + (int)std::lround(60 * energy);
      debt_ += std::clamp(want - (int)ps_.size(), 0, 40) * dt * 2;
      while (debt_ >= 1 && (int)ps_.size() < kMost) {
        debt_ -= 1;
        P p;
        p.x = u() * w; p.y = u() * h;
        p.vx = (u() - 0.5) * h * 0.02; p.vy = -(0.01 + 0.03 * u()) * h;
        p.life = 6 + u() * 8; p.size = (0.2 + 0.8 * u()) * h * 0.005; p.seed = u();
        ps_.push_back(p);
      }
    } else if (kind_ == "rise") {
      const double up = std::max(in.build, in.dropNear);
      debt_ += (10 + 160 * up * up) * dt;
      while (debt_ >= 1 && (int)ps_.size() < kMost) {
        debt_ -= 1;
        P p;
        p.x = u() * w; p.y = h + 10;
        p.vx = 0; p.vy = -(0.25 + 0.9 * up + 0.5 * u()) * h;
        p.life = 1.2 + u(); p.size = (0.3 + 0.5 * u()) * h * 0.008; p.seed = u();
        ps_.push_back(p);
      }
    } else if (kind_ == "rain") {
      debt_ += (5 + 120 * in.high) * dt;
      while (debt_ >= 1 && (int)ps_.size() < kMost) {
        debt_ -= 1;
        P p;
        p.x = u() * w; p.y = -10;
        p.vx = (u() - 0.5) * h * 0.05; p.vy = (0.4 + 0.6 * u()) * h;
        p.life = 1.5 + u(); p.size = (0.2 + 0.3 * u()) * h * 0.006; p.seed = u();
        ps_.push_back(p);
      }
    }
    for (auto& p : ps_) {
      p.age += dt;
      if (kind_ == "sparks") {
        const double k = std::pow(0.35, dt);
        p.vx *= k;
        p.vy = p.vy * k + h * 0.25 * dt;
      } else if (kind_ == "dust") {
        p.vx += std::sin(p.age * 0.7 + p.seed * 9) * h * 0.004 * dt;
      }
      p.x += p.vx * dt;
      p.y += p.vy * dt;
    }
    std::vector<P> keep;
    keep.reserve(ps_.size());
    for (auto& p : ps_)
      if (p.age < p.life && p.y >= -40 && p.y <= h + 40 && p.x >= -40 && p.x <= w + 40) keep.push_back(p);
    ps_.swap(keep);
  }

  // Instances: x, y (pixels from the top), radius, r, g, b, a.
  void instances(const ParticleInputs& in, std::vector<float>& out) const {
    for (const auto& p : ps_) {
      const double k = p.age / p.life;
      double alpha, size = p.size;
      if (kind_ == "sparks") {
        alpha = (1 - k) * (1 - k);
        size *= 1 + k * 0.5;
      } else if (kind_ == "dust") {
        alpha = std::sin(k * M_PI) * (0.35 + 0.65 * (0.5 + 0.5 * std::sin(in.time * (1 + p.seed * 2) + p.seed * 20)));
      } else if (kind_ == "rise") {
        alpha = std::sin(k * M_PI);
        size *= 2.2;
      } else {
        alpha = std::sin(k * M_PI) * 0.8;
      }
      if (alpha <= 0.01) continue;
      const float s = (float)p.seed;
      out.insert(out.end(), {(float)p.x, (float)p.y, (float)size,
                             in.primary[0] + (in.accent[0] - in.primary[0]) * s,
                             in.primary[1] + (in.accent[1] - in.primary[1]) * s,
                             in.primary[2] + (in.accent[2] - in.primary[2]) * s, (float)std::min(1.0, alpha)});
    }
  }

 private:
  struct P { double x = 0, y = 0, vx = 0, vy = 0, life = 0, age = 0, size = 1, seed = 0; };
  static constexpr int kMost = 600;
  double u() { return std::uniform_real_distribution<double>(0, 1)(rng_); }
  std::string kind_;
  std::mt19937 rng_;
  std::vector<P> ps_;
  double kickWas_ = 0, debt_ = 0;
};

// The soft disc each particle is: white at the middle, 0.55 at a quarter out, nothing
// at the rim (the Flutter sprite's gradient), coloured by the instance, added.
static const char* kParticleVert = R"(#version 300 es
layout(location = 0) in vec4 iPos;    // x, y, radius (pixels, y from the top), unused
layout(location = 1) in vec4 iColour;
uniform vec2 uResolution;
out vec2 vLocal;
out vec4 vColour;
void main() {
  vec2 corner = vec2(float(gl_VertexID & 1), float((gl_VertexID >> 1) & 1)) * 2.0 - 1.0;
  vLocal = corner;
  vColour = iColour;
  vec2 px = iPos.xy + corner * iPos.z;
  vec2 ndc = px / uResolution * 2.0 - 1.0;
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
}
)";

static const char* kParticleFrag = R"(#version 300 es
precision highp float;
in vec2 vLocal;
in vec4 vColour;
out vec4 fragColor;
void main() {
  float r = length(vLocal);
  float a = r < 0.25 ? mix(1.0, 0.55, r / 0.25) : mix(0.55, 0.0, clamp((r - 0.25) / 0.75, 0.0, 1.0));
  fragColor = vec4(vColour.rgb * a * vColour.a, 1.0);
}
)";

}  // namespace ws
