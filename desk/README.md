# WetOwl Desk (v2)

The native desktop app: booth, show control, crate, pool. Rust. The plan is
`~/.claude/plans/wetowl-v2.md` §10. The Flutter app (`../app`) is v1, frozen at the
`v1-final-candidate` tag.

```
crates/wo-engine-sys   the booth engine's C API (../app/native/engine, compiled in by build.rs)
crates/wo-engine       the engine, safe: one at a time, sources owned by whoever fills them
crates/wo-decode       records decoded in-process (symphonia), resampled exactly (rubato FFT),
                       MP4 edit lists honoured so beat grids line up with ffmpeg's samples
apps/wo-play           two records on two decks, B synced to A: the stack end to end
```

## Build and test

```
cargo test --release                          # engine SYNC/loop numbers, decode vs ffmpeg
cargo run --release -p wo-play -- A.m4a B.m4a --keylock [--offline out.wav]
```

Tests run release: the engine is always optimised, and Rubber Band in a debug build
cannot keep up. `.cargo/config.toml` holds builds to three jobs (the dev laptop has
~5.7 GB). Listening without a sound: `pactl load-module module-null-sink
sink_name=X`, then `PULSE_SINK=X`.

## Measured (2026-10-30, Ryzen 5 3500U)

- SYNC through Rust: worst 0.02 ms (key lock off), 0.48 ms (on); loop wraps 0.025 ms.
- Decode: 150 s of AAC in 0.41 s; 0 frames off ffmpeg, same length (44.1 and 32 kHz).
- Real time, two decks: 1 % of the audio budget with key lock off; ~43 % with it on
  (Rubber Band R3), 3 late callbacks around a deck's start (the stretcher being made).
