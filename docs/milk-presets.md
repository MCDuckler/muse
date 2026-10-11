# MilkDrop in the show

The stage's `MilkDrop` scene is projectM — the open MilkDrop 2 — run as a helper
(`app/native/milk/wetowl-milk`) beside the app, fed the records' own sound at the
needle and the show's numbers, and read for its frames. Presets are MilkDrop's text
files: the 552 originals ship with the app, your own go in the data folder
(`~/.local/share/io.wetowl.muse/milk/mine/` on Linux), and any folder of `.milk`
files can be brought in from the browser (Show tile → MilkDrop → Presets).

## What a preset can read

Everything MilkDrop gives (`bass`, `mid`, `treb`, `*_att`, `time`, `frame`,
`progress`, `fps`, `q1`–`q32`, …), plus — WetOwl's patch — the show, by name, in
per-frame, per-vertex, shape and waveform code. All 0..1 unless said.

| name | what |
|---|---|
| `wo_beat`, `wo_bar`, `wo_phrase` | 0..1 through the beat, the bar, the four-bar phrase, on the record's grid |
| `wo_beat_in_bar` | 0..3 |
| `wo_bar_index` | the bar, counted from the record's first downbeat |
| `wo_bpm` | the record's tempo |
| `wo_playing` | 1 while the master deck runs |
| `wo_kick`, `wo_onset` | the kick drum and any onset, now |
| `wo_sub`, `wo_low`, `wo_mid`, `wo_high`, `wo_air` | the bands, through the mixer (EQ, filter, fader) |
| `wo_drums`, `wo_vocals` | the stems' share |
| `wo_hit_kick`, `wo_hit_snare`, `wo_hit_top` | hits: 1 as one lands, gone in ~0.2 s |
| `wo_beat_decay`, `wo_bar_decay`, `wo_downbeat` | exponential falls from each beat / bar / beat one |
| `wo_exposure` | 0.35..1.2, follows the loudness slowly |
| `wo_loud` | the loudness, now |
| `wo_band_low`, `wo_band_mid`, `wo_band_high` | the bands against the record's own loud |
| `wo_energy` | the bar's energy from the analysis |
| `wo_build` | up a build, 0..1 |
| `wo_drop` | 1 as a drop lands, 0 thirty-two beats off |
| `wo_drop_beats` | beats until the next drop (999 none) |
| `wo_breakdown` | 1 in a breakdown |
| `wo_section` | 0 none, 1 intro, 2 verse, 3 build, 4 drop, 5 chorus, 6 breakdown, 7 outro, 8 other |
| `wo_section_k` | 0..1 through the section |
| `wo_vocal`, `wo_hook` | the voice's share; 1 on the hook |
| `wo_hit` | the hands' hit (and the director's on a drop), falling over 0.35 s |
| `wo_intensity` | the hands' intensity macro |
| `wo_hue`, `wo_hue2`, `wo_hue3` | the palette's primary, secondary, accent hues, 0..1 round the wheel |
| `wo_mix` | how far through a mix, 0 off |
| `wo_level_a`, `wo_level_b` | each deck's share of the output |
| `wo_cam_motion`, `wo_cam_x`, `wo_cam_y` | the room's camera, where it is on |

A shipped preset knows none of these — but it reads `bass`, `mid`, `treb` and
their `_att` followers, and those are the show's too: the helper is told them every
tick from WetOwl's own bands and hits on the record's grid (a kick lands `bass` at
2–3, where presets' thresholds are), in place of projectM's guess from an FFT. So
every preset follows the beat the booth hears. On top the director cuts on hits
and drops, blends every so many bars and holds through a breakdown; the scene's
own shader steps in on the kick and flashes on a hit.

The show tile's `MilkDrop presets` button opens the browser (search, ★, folders
brought in, the director's rules) and the maker (`New preset` / `Edit this one`);
the two pads beside the preset's name put MilkDrop under every scene, or hold the
stage on MilkDrop alone with ‹ › stepping its presets.

## Writing one

```
per_frame_1=zoom = zoom + 0.08*wo_hit_kick;
per_frame_2=rot = rot + 0.02*sin(wo_bar*6.2832);
per_frame_3=decay = 0.96 + 0.03*wo_breakdown;
per_frame_4=wave_r = 0.5 + 0.5*sin(wo_hue*6.2832);
per_frame_5=q1 = wo_drop;
```

`q1`–`q32` set in per-frame code reach the warp and composite shaders as `q1`…
so a drop can drive a shader too. The maker (Presets → New) writes lines like
these for you from a list of reactions, and shows the helper's word on anything
that will not compile.

## The helper

`wetowl-milk --size WxH --fps N --textures DIR` reads commands on stdin (one a
line) and writes frames on stdout (`MILK`, width, height, sequence as little-endian
u32, then RGBA top row first). Commands: `size W H`, `fps N`, `preset PATH`,
`preset-soft PATH`, `data N` + N bytes, `data-soft N`, `lock 0|1`,
`var NAME VALUE`, `vars N=V …`, `pcm N` + N int16 mono 44.1 kHz samples,
`audio B M T BA MA TA` (the levels preset code reads as bass/mid/treb and their
followers; `audio off` for projectM's own), `beat S`, `textures DIR`, `quit`. On
Linux it renders through EGL without a window (surfaceless, a GPU device, or the
default display) — so it works on a desk with no window of its own and in the
headless bench; on Windows through a window that is never shown. Built by
`flutter build linux` / `flutter build windows` through `linux/CMakeLists.txt` and
`windows/CMakeLists.txt` (Linux needs cmake, git, EGL and OpenGL headers; Windows
needs GLEW from vcpkg with its toolchain file in `CMAKE_TOOLCHAIN_FILE`). A Mac
helper is still to come.

The patch to projectM is `app/native/milk/projectm-wetowl.patch` (adds
`projectm_set_custom_variable`, `projectm_set_audio_levels` and
`projectm_opengl_set_target_framebuffer`); the version is pinned in its
CMakeLists, and the fetched source is keyed by the patch's hash, so a changed
patch is a fresh fetch.
