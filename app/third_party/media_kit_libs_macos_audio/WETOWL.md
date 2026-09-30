# media_kit_libs_macos_audio 1.1.4, with the libmpv that has the booth's filters

This is `media_kit_libs_macos_audio` 1.1.4 from pub.dev (MIT, see LICENSE), vendored so
that one line could change: which libmpv build it downloads. The app uses it through
`dependency_overrides` in `app/pubspec.yaml`. `example/` was left out.

## Why

The same reason as `../media_kit_libs_ios_audio/WETOWL.md`. On a Mac, as on Linux and
Windows, every player is libmpv (see `app/lib/main.dart`), and the booth's decks run
through one ffmpeg filter chain each (`app/lib/src/state/booth/mixer_desktop.dart`):
`asplit`, `lowpass`, `highpass`, `volume`, `amix`, `aecho`, `alimiter`, `aloop`,
`channelsplit`, `join`. The flavour media_kit ships (`audio-default`) has almost none of
them. `audio-encodersgpl` from the same release (libmpv-darwin-build v0.6.0, the one this
package was built against) is `audio-full` plus `--enable-filters` — every filter above,
checked in the binary's libavfilter — with the Opus decoder and Ogg demuxer the stems
need. Universal (arm64 + x86_64), like the rest of the app.

No Rubber Band in any flavour, so a synced deck on a Mac stretches with mpv's own
scaletempo2, as on an iPhone.

## What changed

| File | Change |
|---|---|
| `macos/Makefile` | The download: `…_macos-universal-audio-encodersgpl.tar.gz` and its sha256. |

## Updating upstream

Copy the new release over this directory, keep this file, and point the Makefile at
the `encodersgpl` tarball of whatever libmpv-darwin-build version it names (sha256 from
the downloaded file).
