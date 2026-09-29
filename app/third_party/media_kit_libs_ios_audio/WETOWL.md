# media_kit_libs_ios_audio 1.1.4, with the libmpv that has the booth's filters

This is `media_kit_libs_ios_audio` 1.1.4 from pub.dev (MIT, see LICENSE), vendored so
that one line could change: which libmpv build it downloads. The app uses it through
`dependency_overrides` in `app/pubspec.yaml`. `example/` was left out.

## Why

The booth's decks on a desk run through one ffmpeg filter chain each (see
`app/lib/src/state/booth/mixer_desktop.dart`): `asplit`, `lowpass`, `highpass`,
`volume`, `amix`, `aecho`, `alimiter`, `aloop`, `channelsplit`, `join`. The flavour
media_kit ships for iOS (`audio-default`) builds ffmpeg with two filters, `equalizer`
and `overlay`, and nothing else — checked in the binary: its libavfilter is 183 KB. The
`audio-full` flavour adds decoders, not filters.

`audio-encodersgpl` from the same release (libmpv-darwin-build v0.6.0, the one this
package was built against) is `audio-full` plus `--enable-filters`: every filter above
is in it, with the Opus decoder and the Ogg demuxer the booth's stems need. It also
carries encoders and Vorbis nobody here uses — a few megabytes, and the reason for the
name, not a licence the app takes on: its ffmpeg is not built with `--enable-gpl`.

There is no Rubber Band in any iOS flavour, so a deck there stretches with mpv's own
scaletempo2, as on a desk whose mpv has none.

## What changed

| File | Change |
|---|---|
| `ios/Makefile` | The download: `…_ios-universal-audio-encodersgpl.tar.gz` and its sha256. |

## Updating upstream

Copy the new release over this directory, keep this file, and point the Makefile at
the `encodersgpl` tarball of whatever libmpv-darwin-build version it names (sha256 from
the downloaded file).
