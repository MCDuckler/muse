# just_audio 0.10.6, with WetOwl's iOS equalizer and a position that is told

This is `just_audio` 0.10.6 from pub.dev (MIT, see LICENSE), vendored so that two things
could be added: an equalizer for iOS, and a position the engines volunteer. The app uses it through `dependency_overrides` in
`app/pubspec.yaml`. `example/` and `test/` were left out.

## What was added

AVPlayer has no equalizer and cannot be routed through one, but it will hand over each
item's samples as they play (an `MTAudioProcessingTap` on the item's audio mix). That has
to be set where the player item is made, which is inside this plugin — hence the copy.

| File | Change |
|---|---|
| `darwin/just_audio/Sources/just_audio/WetowlEq.m` + `include/just_audio/WetowlEq.h` | **New.** The filters (RBJ biquads), the tap, and the `wetowl/eq` method channel. |
| `.../UriAudioSource.m` | One import, and `[WetowlEq attachTo:item];` at the end of `createPlayerItem:`. |
| `.../JustAudioPlugin.m` | One import, and `[WetowlEq registerWithMessenger:…]` in `registerWithRegistrar:`. |
| `darwin/just_audio.podspec`, `darwin/just_audio/Package.swift` | Link `MediaToolbox` and `AVFoundation`. |

## What was added, again

Upstream tells Dart where a record is when something *happens* to it — a state change, a
seek, the buffer growing — and Dart carries the position forward itself at the playback
speed in between. For a seek bar that is plenty: a local file that is fully buffered stops
producing events altogether, and the bar still slides.

For holding two records on one beat it is not. The booth's loop then has nothing the
engine said to work from: it measures its own arithmetic against itself, which always
agrees, and whatever the audio clock and the system clock have quietly done to each other
goes unseen until some unrelated event lands it all at once as a step. A control loop
with no measurement in it is not a control loop.

So while a player is actually playing, both engines now say where they are ten times a
second. It is one local call each — the same one the seek bar already makes — over a
channel that was already carrying these events.

| File | Change |
|---|---|
| `android/.../AudioPlayer.java` | **New.** `positionWatcher`, `startWatchingPosition()`, started from `STATE_READY` and `play`, stopped in `dispose`. |
| `darwin/.../AudioPlayer.m` | **New.** `tellThePosition`, and the periodic time observer installed always at 100 ms rather than only on systems too old for `timeControlStatus`. |

`test/fake_audio.dart`'s `reportEvery` is this behaviour in the test engine, and its
`truePosition` is how a test asks where a record really is rather than where the app
believes it is.

Every change in an upstream file is marked with a `WetOwl:` comment:
`grep -rn "WetOwl" darwin android` finds them all.

## Updating upstream

Copy the new release over this directory, keep `WetowlEq.{h,m}` and this file, and
re-apply the small edits above — the four for the equalizer and the two for the position. The Dart side is `app/lib/src/state/eq_engines.dart`
(`ChannelEqEngine`).

## The rule it keeps

No tap is attached to anything until the equalizer has been switched on at least once,
and a tap that is switched off passes samples through untouched — so somebody who never
uses the equalizer is playing music exactly as upstream does.
