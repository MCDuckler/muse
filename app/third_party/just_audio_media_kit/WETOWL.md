# just_audio_media_kit 2.1.0, with two accessors

This is `just_audio_media_kit` 2.1.0 from pub.dev (MIT, see LICENSE), vendored so that
the booth can reach the mpv player underneath a deck and set its audio filters — the
kills and the filter a deck has on a desk. Nothing else is changed.

| File | Change |
|---|---|
| `lib/mediakit_player.dart` | `MediaKitPlayer.raw`: the media_kit `Player`. |
| `lib/just_audio_media_kit.dart` | `playerFor(id)` and `instanceIfRegistered`; `routed`, the instance a router sends players to when this is not the registered platform (the booth's decks on iOS, `app/lib/src/state/booth/deck_router.dart`). |

| `lib/mediakit_player.dart` | The error listener: only "Failed to open <this record>" puts the player in idle. Upstream did it for any error mpv logged without a file name — including every audio filter it could not build, which made just_audio dispose the player under a booth deck whose best chain (Rubber Band) was not in that mpv. |

Every change is marked with a `WetOwl:` comment. The other half is
`AudioPlayer.platformId` in `third_party/just_audio`, which is how a deck names its
player to this plugin. The Dart side is `app/lib/src/state/booth/mixer_desktop.dart`.

## Updating upstream

Copy the new release over this directory, keep this file, and re-apply the two
accessors above.
