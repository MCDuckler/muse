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

The media session is unchanged: it belongs to the first player made, which is the app's
own `PlayerService`. The decks have no notification and no lockscreen controls, which is
correct — the booth is a room somebody is standing in, not something to work from a
lockscreen.

## Updating upstream

Copy the new release over this directory, keep this file, and re-apply the three
changes above.
