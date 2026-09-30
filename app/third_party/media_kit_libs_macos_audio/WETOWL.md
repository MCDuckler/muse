# media_kit_libs_macos_audio 1.1.4, with a libmpv the booth can steer

This is `media_kit_libs_macos_audio` 1.1.4 from pub.dev (MIT, see LICENSE), vendored so
that one line could change: which libmpv build it downloads. The app uses it through
`dependency_overrides` in `app/pubspec.yaml`. `example/` was left out.

## Why

The same reason as `../media_kit_libs_ios_audio/WETOWL.md`. On a Mac, as on Linux and
Windows, every player is libmpv (see `app/lib/main.dart`), and the booth's decks run
through one ffmpeg filter chain each (`app/lib/src/state/booth/mixer_desktop.dart`):
`asplit`, `lowpass`, `highpass`, `volume`, `amix`, `aecho`, `alimiter`, `aloop`,
`channelsplit`, `join`. The flavour media_kit ships (`audio-default`) has almost none of
them. `audio-encodersgpl` is `audio-full` plus `--enable-filters` — every filter above,
checked in the binary's libavfilter — with the Opus decoder and Ogg demuxer the stems
need. Universal (arm64 + x86_64), like the rest of the app.

## And built here, for one thing mpv 0.36 cannot do

Every libmpv-darwin-build release (v0.6.0 up to v0.7.3) is mpv 0.36.0, and 0.36's
`af-command` cannot name the filter it is for: the booth turns one band with
`af-command wetowl volume 0.01 volume@low`, and 0.36 refused the fourth argument ("has
only 3 arguments") — logged, not thrown, so nothing noticed. Without it a command would
reach every volume in the chain. And their ffmpeg is 6.0, which named a filter written
`volume@low` just `low` (FFmpeg #10226, fixed in 6.0.1), so a target was never found.
So the archive this downloads is media-kit's own recipe at v0.7.3 plus the two patches in
`libmpv/` — mpv's target, as mpv 0.37 has it, and FFmpeg's own 6.0.1 fix — built by
`.github/workflows/libmpv-darwin.yml` and kept as the release
`libmpv-darwin-v0.7.3-wetowl2` of this repository. `integration_test/desk_engine_test.dart`
fails on a libmpv without them.

No Rubber Band in any flavour, so a synced deck on a Mac stretches with mpv's own
scaletempo2, as on an iPhone.

## What changed

| File | Change |
|---|---|
| `macos/Makefile` | The download: this repository's `…_macos-universal-audio-encodersgpl.tar.gz` and its sha256. |
| `libmpv/mpv-filter-command-target.patch` | **New.** The mpv patch the archive is built with. |
| `libmpv/ffmpeg-graphparser-instance-name.patch` | **New.** The ffmpeg patch (FFmpeg's 2fd86d9afa). |

## Updating upstream

Copy the new release over this directory, keep this file and `libmpv/`. If the
libmpv-darwin-build it names is mpv 0.37 or later, point the Makefile at its own
`encodersgpl` tarball and drop the patch; otherwise run libmpv-darwin.yml at that
version (a new `version`) and point the Makefile at the result.
