# muse — client

One Flutter codebase for web, Android and iOS. `just_audio` + `just_audio_background`
give queue, gapless, background playback and lockscreen controls through one API on all
three, which is the reason the client is Flutter and not React Native.

## Structure

```
lib/src/api/models.dart    Track, Queue, Playlist — the wire shapes
lib/src/api/client.dart    REST + SSE. Knows about 202-vs-200 and 409 conflicts.
lib/src/state/player.dart  just_audio wrapper. Nothing above it knows where audio comes from.
lib/src/state/app_state.dart  Queues, playlists, login, live events.
lib/src/ui/                Login, queues, search, library, the always-there player bar.
```

## Two decisions worth keeping

**Loudness is attenuation only.** The server stores `gain_db` against -14 LUFS. A player
can only turn down (volume caps at 1.0), so a positive gain on a quiet track is ignored
rather than pushed into clipping — the same call ReplayGain's clipping prevention makes.

**A queue is an object, not "the" queue.** Each has its own order, cursor, shuffle and
repeat. Order is versioned (`rev`, 409 on conflict, merge from the live state); the cursor
is not, because the device that is playing is the authority on where playback is.

## Running

```bash
export PATH="$HOME/.local/flutter/bin:$PATH"
flutter pub get
flutter test          # unit tests, no browser or device needed
flutter run -d chrome # or: flutter build web
```

Android and iOS need their own toolchains (Android SDK / Xcode). iOS is a free 7-day
sideload: keep the bundle id stable so downloads and settings survive a re-sign.
