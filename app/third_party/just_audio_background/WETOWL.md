# just_audio_background 0.0.1-beta.17, with a way past the single player

This is `just_audio_background` 0.0.1-beta.17 from pub.dev (MIT, see LICENSE), vendored
so that a *second* player can exist on a phone. Upstream refuses one:

    throw PlatformException(message: "just_audio_background supports only a single
    player instance")

which is right for what it does — there is one notification, one lockscreen and one set
of headset buttons — but the booth is two records at once, so on Android and iOS the
booth could not make a sound at all. Every change is marked with a `WetOwl:` comment;
`grep -rn "WetOwl" lib` finds them.

| Change | Why |
|---|---|
| `init` passes a second player to the real platform instead of throwing | The booth's decks are ordinary players. |
| `disposePlayer` / `disposeAllPlayers` let go of those through the real platform | They were never this plugin's to hold. |
| `AudioSourceExtension.shuffleIndices` plays a concatenation as listed when its order is not a permutation of its children | Same failure one step earlier: the extension indexes its children by the order before `_updateShuffleIndices` gets to look. The order went bad because just_audio sent its *live* shuffle list in the load message (fixed there, see just_audio/WETOWL.md); this keeps a bad one from ever killing a load again. |
| `_updateShuffleIndices` ignores a shuffle order that does not describe the sequence | It builds an inverse by writing at `order[i]` into a list as long as the order, so anything but a permutation of `0..n-1` is out of range. With several players sharing one handler, the order and the source come from different players: measured on an iPhone as `RangeError (length): Invalid value: Only valid value is 0: 1` thrown out of a track load, which left playback dead until a restart. |

| `MediaSessionHooks`, `JustAudioBackground.hooks`, `refreshState()`, `notifyChildrenChanged()` | Android Auto browses the session: a tree of things to play, a search, buttons beside play and pause (the heart), repeat and shuffle pressed in the car. The engine cannot answer any of that; the app can, through one object. The handler's `getChildren`/`subscribeToChildren`/`search`/`playFromMediaId`/`playFromSearch`/`customAction` forward to it, `_broadcastState` adds its controls and advertises repeat/shuffle/play-from actions. Without hooks everything is as before. |
| `applyRepeatMode` / `applyShuffleMode` split from `setRepeatMode` / `setShuffleMode` | The app's own `setLoopMode` used to go through the same method the car presses. The app's path goes straight to the engine; the session's path asks the hooks, so repeat pressed in the car means what repeat means to the queue. |

The media session is otherwise unchanged: it belongs to the first player made, which is the app's
own `PlayerService`. The decks have no notification and no lockscreen controls, which is
correct — the booth is a room somebody is standing in, not something to work from a
lockscreen.

## Updating upstream

Copy the new release over this directory, keep this file, and re-apply the changes
above.
