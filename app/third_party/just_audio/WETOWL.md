# just_audio 0.10.6, with WetOwl's iOS equalizer

This is `just_audio` 0.10.6 from pub.dev (MIT, see LICENSE), vendored so that one thing
could be added: an equalizer for iOS. The app uses it through `dependency_overrides` in
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

Nothing in `lib/` or `android/` was touched. Every change in an upstream file is marked
with a `WetOwl:` comment: `grep -rn "WetOwl" darwin` finds them all.

## Updating upstream

Copy the new release over this directory, keep `WetowlEq.{h,m}` and this file, and
re-apply the four small edits above. The Dart side is `app/lib/src/state/eq_engines.dart`
(`ChannelEqEngine`).

## The rule it keeps

No tap is attached to anything until the equalizer has been switched on at least once,
and a tap that is switched off passes samples through untouched — so somebody who never
uses the equalizer is playing music exactly as upstream does.
