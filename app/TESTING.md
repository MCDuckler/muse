# Testing the client

```bash
export PATH="$HOME/.local/flutter/bin:$PATH"
flutter test                     # unit: wire shapes, gain curve
```

## Browser test (the one that catches the real bugs)

Unit tests never saw the failures that made playback and queues unreliable, because
none of them lived in a single call — they lived in how the player reacted to queue
updates, and in a JSON field that changes shape between two endpoints. This drives the
real widgets in a real browser against a real server.

```bash
# one-time: Chrome + a matching chromedriver, both user-local
#   ~/.local/chrome/chrome-linux64/chrome
#   ~/.local/chromedriver-linux64/chromedriver
# chromedriver picks the first chrome on PATH, so shadow the system one:
export PATH="$HOME/.local/chromebin:$HOME/.local/chromedriver-linux64:$PATH"
nohup chromedriver --port=4444 >/tmp/chromedriver.log 2>&1 & disown

export CHROME_EXECUTABLE="$HOME/.local/chrome/chrome-linux64/chrome"
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/app_test.dart \
  -d web-server --browser-name=chrome \
  --web-browser-flag="--headless=new" \
  --web-browser-flag="--no-sandbox" \
  --web-browser-flag="--use-gl=swiftshader" \
  --web-browser-flag="--enable-unsafe-swiftshader" \
  --web-browser-flag="--autoplay-policy=no-user-gesture-required" \
  --dart-define=MUSE_SERVER=https://your.server \
  --dart-define=MUSE_USER=you --dart-define=MUSE_PASS=...
```

Notes that cost time to learn:

- The test page is served from `localhost`, so the server needs `cors_origin_regex`
  set for localhost. Production is same-origin and needs none.
- `--autoplay-policy=no-user-gesture-required` is required: a `tester.tap` is a
  synthetic Flutter gesture, not browser user-activation, so audio would never start.
- Scope tab taps to the `NavigationBar`. `Icons.queue_music` is also the empty-state
  illustration, and tapping that leaves you on the wrong page asserting against it.
- Section headers are uppercased by the widget, so find `IN YOUR LIBRARY`.

## Screenshots

The driver writes any `binding.takeScreenshot('name')` to `build/screenshots/name.png`
(that is what `integration_test_driver_extended` is for). The player's artwork is the
reason it exists: a record standing up, lying down, or half way is something to look at
rather than something to assert about.

## Player calls inside a widget test

`testWidgets` runs its body under a fake clock. Anything the player awaits — the stub
server, the fake engine's events — only moves in real time, so
`await app.player!.loadQueue(...)` *inside* a `testWidgets` body never returns and the
test sits there until the runner kills it. Either do it in `setUp` (real async), or
wrap it: `await tester.runAsync(() => app.player!.playAt(1))`. Plain `test()` files
such as `player_engine_test.dart` do not have this problem.

## The skip test

`integration_test/skip_test.dart` exists because the player screen can look right while
the audio engine is still on the previous song. It asserts on what the engine reports —
the file it loaded and how long that file is — and, when it fails, prints what the
browser's media element was actually told, by hooking `HTMLMediaElement` (just_audio's
elements are detached from the document, so they cannot be found by querying the DOM).

That hook is what found the real bug: one element, one src assignment, then nothing but
play/pause for the whole session.

## The discovery test

`integration_test/discovery_test.dart` is about the album and artist pages showing the
whole record rather than the part of it we downloaded. It picks an album the library
only has some of, and asserts that the page lists more songs than the library holds,
that the ones we hold are matched into their places, that the artist has a discography
rather than a track list, and that following puts that artist's records in the feed.
Then it pushes the real album page onto the app's own navigator and checks the missing
rows are on screen.

`integration_test/spotify_connect_test.dart` hooks `window.open` to return `null`, the
way a popup blocker does, and asserts the Connect button opens Spotify from the tap
itself — a browser only opens a window while it can still see the interaction that
asked for one.
