# The Siebenschläfer bank

What the Siebenschläfer scene draws from (`lib/src/ui/show/show_meme.dart`, the looks in
`show_meme_bits.dart`). Everything here is in `bank.json` and can be edited by hand; a
rebuild picks it up.

- **photos**: `set` is `sleep`, `wake` (peeking out of something), `stare`, `chaos`, or
  for the history lesson `old` (engravings), `roman` (gliraria), `devil`, `hunt`.
  `face` is the face's middle x, y (0..1 of the picture) and its radius as a share of
  the picture's height. `eyes` are the eye points, used for the zoom of a build and the
  rare laser eyes. A photo without `eyes` is never lasered.
- **stickers**: cut-outs with a white outline. `set` is `sleep` or `awake`.
  `peek: true` marks one that can rise from the bottom edge, head first, in a build.
- **clips**: real footage as numbered WebP frames in `clips/<id>/`, with `track`, the
  animal's position in each frame, so the edit can zoom on it.
- **captions**: the lines per mood (`sleep`, `wake`, `rage`, `vibe`), shown a word a beat
  over plain photographs only. The other pools feed the looks and gags: `cards`,
  `countdown`, `facts`, `polaroid`, `roman`, `devil`, `hunt`, `news`, `ticker`,
  `stamps`, `bubbles`, `errors`, `top7`, `brain` (four labels split by `|`), `nobody`
  (two lines split by `|`), `clip`, `loading`, `emoji`.
- **handle**: the small watermark that moves every eight bars.

To add a photo, put a WebP no longer than 1280 px on its long side in `photos/`, add an
entry with its size, set, face and eyes, and add its author and licence to `CREDITS.md`.

To look at one look or one style on the stage, set these before `wetowl --stage --demo
--scene siebenschlaefer`:

    WETOWL_MEME_BIT=screensaver|wall|polaroids|parallax|kaleido|strips|spotlight|film|
                    rings|duotone|clip|history|sunburst|crowd|nobody|brain|top7|news|
                    stamp|bubble|cursor|pip|dvd|spectrum|errors|tbc|wasted
    WETOWL_MEME_STYLE=fried|phonk|vapor|clean|y2k
