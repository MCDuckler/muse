# just_audio_media_kit 2.1.0, with two accessors

This is `just_audio_media_kit` 2.1.0 from pub.dev (MIT, see LICENSE), vendored so that
the booth can reach the mpv player underneath a deck and set its audio filters — the
kills and the filter a deck has on a desk. Nothing else is changed.

| File | Change |
|---|---|
| `lib/mediakit_player.dart` | `MediaKitPlayer.raw`: the media_kit `Player`. |
| `lib/just_audio_media_kit.dart` | `playerFor(id)` and `instanceIfRegistered`. |

Every change is marked with a `WetOwl:` comment. The other half is
`AudioPlayer.platformId` in `third_party/just_audio`, which is how a deck names its
player to this plugin. The Dart side is `app/lib/src/state/booth/mixer_desktop.dart`.

## Updating upstream

Copy the new release over this directory, keep this file, and re-apply the two
accessors above.
