# Desk UI bake-off: egui vs Slint

The same smoked-glass booth (mockup: https://claude.ai/artifact/9vSZUxxAHYJVHzdfL9eg6P,
tokens `design/tokens.json`), built twice on one shared core (`wo-deskcore`). Both
measured while the Auto DJ mixes two keylocked records (the engine running for real),
with `--bench`.

## Linux: HP 17, Ryzen 5 3500U / Vega 8, Mesa radeonsi, 2026-10-30

Setup: headless mutter on the real GPU, a 1920×1080@60 virtual monitor (window
1920×1045), 20–30 s per run after a 3 s warm-up, two runs each (`bakeoff/headless.sh`).

| | egui · glow | Slint · femtovg |
|---|---|---|
| fps (of 60) | **59.6 – 59.9** | 49.5 – 50.8 |
| frame interval p99 | **18 – 24 ms** | 27 – 31 ms |
| frames over 25 ms | **0 – 11** of ~1,200 | 26 – 169 of ~1,000 |
| our code per frame (p50) | **1.0 ms** (mesh building) | 6.3 ms (waveforms rasterised on the CPU) |
| toolkit's own render (p50) | — (in the CPU figure) | 10 – 11.5 ms |
| CPU, % of one core | **57 – 66 %** | 125 – 140 % |
| peak memory | 182 MB | 189 MB |
| binary (release, Linux) | **34 MB** | 47 MB (femtovg + Skia) |
| UI code | 720 lines of Rust | 896 lines of .slint + 364 lines of Rust |

Not measurable here: egui's **wgpu** backend and Slint's **Skia** renderer both stall in
the headless compositor (no Wayland frame callback after the first frame). This is the
harness, not the toolkits. The Windows run below covers both.

Slint's first version drew the waveforms as `Path` elements from per-frame SVG
strings. Rasterising them into an image per frame is the idiomatic route for live
graphics in Slint, and it is the version measured here. A GL underlay would move that
6 ms to the GPU, but femtovg's ~10 ms for the rest of the scene would remain.

## Windows: Joe's desk

The CI artifact `wetowl-desk-bakeoff-windows` (workflow "Desk bake-off") holds
`desk-egui.exe`, `desk-slint.exe` and `bench.cmd`. Running `bench.cmd` measures:
- egui on wgpu (DX12)
- egui on glow (WGL)
- Slint on femtovg
- Slint on Skia

Each run takes 30 s and writes `results/bench-*.json` plus screenshots. The booths play
the WetOwl app's own fetched records (`%APPDATA%\io.wetowl\muse\fetched`), else two
synthesised ones.

| | egui · wgpu | egui · glow | Slint · femtovg | Slint · Skia |
|---|---|---|---|---|
| fps | | | | |
| frames over 25 ms | | | | |
| CPU % | | | | |

## Beyond the numbers

| | egui | Slint |
|---|---|---|
| Matches the mockup | yes (screenshots alike) | yes |
| Live graphics | GPU meshes per frame: natural | images per frame or a GL underlay |
| Layout | hand arithmetic in Rust | real layouts, elide, components |
| Design iteration | recompile (~4 s incremental) | live preview of .slint possible |
| State | immediate mode: read the snapshot, draw | properties set from Rust each frame (RefCell care) |
| Text input, accessibility | real widgets (TextEdit, AccessKit); painted controls need their own | built into the elements |
| Renderers | wgpu (Vulkan/DX12/Metal), glow | femtovg, Skia, software |

**Decision (2026-10-30, the user): egui.** The Desk is `apps/wetowl-desk`; the Slint booth is in git history (392233b).
