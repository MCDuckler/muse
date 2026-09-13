"""A record, not a JPEG.

The player used to show a flat square, which is what a file looks like rather than what
a record looks like. This renders the pieces of an actual record — the cardboard jacket
and the disc — as separate pictures with their own transparency, so the app can move
them: the jacket stands up, the disc slides out and turns while the music plays.

Everything is rendered once per cover and cached, so the animation costs the client
nothing but moving two textures. Every mark is seeded from the cover's own hash: a
record you know stays the record you know, and no two are alike — different stock,
different wear, sometimes a cut-out hole punched through a corner.
"""
from __future__ import annotations

import math
import pathlib
import random

from PIL import Image, ImageChops, ImageDraw, ImageFilter

CANVAS = 900               # generated size; the client scales it down
JACKET = 0.80              # jacket edge length as a fraction of the canvas
DISC_PEEK = 0.19           # how much of the disc shows in the still composite
TURN = 0.055               # how far the jacket is turned in the still composite

PARTS = ("sleeve", "jacket", "disc")


# ---------------------------------------------------------------- perspective
def _solve(rows: list[list[float]]) -> list[float]:
    """Gaussian elimination. Eight unknowns, no numpy in the image."""
    n = len(rows)
    for i in range(n):
        pivot = max(range(i, n), key=lambda r: abs(rows[r][i]))
        rows[i], rows[pivot] = rows[pivot], rows[i]
        div = rows[i][i]
        rows[i] = [v / div for v in rows[i]]
        for r in range(n):
            if r != i and rows[r][i]:
                factor = rows[r][i]
                rows[r] = [a - factor * b for a, b in zip(rows[r], rows[i])]
    return [row[-1] for row in rows]


def _perspective_coeffs(target: list[tuple[float, float]],
                        source: list[tuple[float, float]]) -> list[float]:
    """Coefficients mapping the output quad back to the source rectangle."""
    rows = []
    for (tx, ty), (sx, sy) in zip(target, source):
        rows.append([sx, sy, 1, 0, 0, 0, -tx * sx, -tx * sy, tx])
        rows.append([0, 0, 0, sx, sy, 1, -ty * sx, -ty * sy, ty])
    return _solve(rows)


# ---------------------------------------------------------------- the edition
def edition(seed: str) -> dict:
    """What kind of copy of this record you ended up with.

    Only the physical facts now: how battered the board is, and whether this copy has a
    hole punched through a corner. Nothing that touches the artwork — see render_jacket.
    """
    rng = random.Random(int(seed[:12], 16))
    condition = rng.choices(["mint", "played", "beat"], weights=[3, 5, 2])[0]
    return {
        "rng": rng,
        "condition": condition,
        "wear": {"mint": 0.35, "played": 1.0, "beat": 1.7}[condition],
        "cut_out": condition != "mint" and rng.random() < 0.14,
        "light": (rng.uniform(-0.75, -0.25), rng.uniform(-0.9, -0.45)),
    }


# ---------------------------------------------------------------- the jacket
def render_jacket(cover: pathlib.Path, seed: str, size: int = CANVAS) -> Image.Image:
    """The cover, square, with softened corners and nothing else.

    The artwork, and nothing done to the artwork.

    Two attempts at "an old record" have been through here and both were wrong in the
    same way. The first composited bare cardboard round the edge of every cover and drew
    scratches over the print, which is a photograph of damage stuck onto somebody's
    sleeve design. The second rebuilt the whole cover out of flat triangles, which is a
    different picture entirely. A record sleeve's artwork is the one thing on this
    screen that somebody else made on purpose, and the right amount to do to it is none.

    What is left is the object rather than the image: corners that are not perfectly
    square, and — from the cover's own hash, so a record you know stays the record you
    know — the odd copy with a hole drilled through a corner by a distributor writing it
    off.

    There was a price sticker in the top corner of one cover in five as well. It was the
    one piece of this that people noticed and did not like: on somebody else's album art
    a pale rectangle does not read as a shop's sticker, it reads as something stuck to
    the screen.

    Square and centred so the client can rotate it about any axis and still have it sit
    where it expects.
    """
    ed = edition(seed)
    rng = ed["rng"]

    art = Image.open(cover).convert("RGB")
    w, h = art.size
    scale = size / min(w, h)
    art = art.resize((max(size, int(w * scale)), max(size, int(h * scale))), Image.LANCZOS)
    w, h = art.size
    face = art.crop(((w - size) // 2, (h - size) // 2,
                     (w - size) // 2 + size, (h - size) // 2 + size)).convert("RGBA")

    if ed["cut_out"]:
        # A hole drilled through the corner: this copy was written off as unsellable.
        hole = Image.new("L", (size, size), 255)
        hx = size * rng.choice([0.06, 0.94])
        hy = size * rng.uniform(0.06, 0.2)
        rad = size * 0.022
        ImageDraw.Draw(hole).ellipse((hx - rad, hy - rad, hx + rad, hy + rad), fill=0)
        face.putalpha(ImageChops.darker(face.getchannel("A"), hole))

    # Corners that are not quite square, and nothing else along any edge.
    #
    # There used to be a strip of board colour across the bottom, meant to read as the
    # thickness of the card seen edge-on. Face on — which is how the player draws it —
    # it is not thickness, it is a grey stripe under the artwork; and with a reflection
    # beneath, the stripe and its mirror image met to make a grey band separating the
    # record from the surface it stands on. Losing it also means the cover no longer
    # has to be squashed by its height to fit back into a square, so the artwork now
    # arrives at exactly the size and shape it was drawn at.
    corners = Image.new("L", (size, size), 0)
    ImageDraw.Draw(corners).rounded_rectangle(
        (0, 0, size - 1, size - 1), radius=int(size * 0.012), fill=255)
    face.putalpha(ImageChops.darker(face.getchannel("A"), corners))
    return face


# ---------------------------------------------------------------- the record
def render_disc(cover: pathlib.Path, colour: tuple[int, int, int], seed: str,
                size: int = CANVAS) -> Image.Image:
    """The disc, centred in a square canvas, transparent outside its edge.

    Centred so the client can spin it with a plain rotation and never have to think
    about where its axle is.
    """
    ed = edition(seed)
    rng = ed["rng"]
    disc = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pen = ImageDraw.Draw(disc)
    r = size / 2 - 1
    pen.ellipse((0, 0, size - 1, size - 1), fill=(15, 14, 16, 255))

    # Grooves. Two bands of them, with the smooth lands between sides, which is what
    # makes a record read as a record rather than a black circle.
    for i in range(46):
        t = i / 46
        rad = r * (0.34 + 0.62 * t)
        shade = 33 + int(15 * math.sin(i * 2.1)) + (10 if 0.44 < t < 0.47 else 0)
        pen.ellipse((size / 2 - rad, size / 2 - rad, size / 2 + rad, size / 2 + rad),
                    outline=(shade, shade, shade + 2, 255), width=max(1, size // 900))

    # The label: the cover art itself, the way a picture label is printed.
    label_r = r * 0.31
    art = Image.open(cover).convert("RGB")
    w, h = art.size
    scale = (label_r * 2) / min(w, h)
    art = art.resize((int(w * scale) + 1, int(h * scale) + 1), Image.LANCZOS)
    w, h = art.size
    art = art.crop(((w - int(label_r * 2)) // 2, (h - int(label_r * 2)) // 2,
                    (w - int(label_r * 2)) // 2 + int(label_r * 2),
                    (h - int(label_r * 2)) // 2 + int(label_r * 2)))
    art = Image.blend(art, Image.new("RGB", art.size, colour), 0.25)
    label_mask = Image.new("L", art.size, 0)
    ImageDraw.Draw(label_mask).ellipse((0, 0, art.size[0] - 1, art.size[1] - 1), fill=255)
    disc.paste(art, (int(size / 2 - label_r), int(size / 2 - label_r)), label_mask)
    pen.ellipse((size / 2 - label_r, size / 2 - label_r,
                 size / 2 + label_r, size / 2 + label_r),
                outline=(0, 0, 0, 110), width=max(2, size // 340))

    hole = r * 0.028
    pen.ellipse((size / 2 - hole, size / 2 - hole, size / 2 + hole, size / 2 + hole),
                fill=(26, 24, 26, 255))

    # Playing wear: hairlines and the dust a record collects, plus the sheen that runs
    # across the vinyl and gives the spin something to catch.
    scratches = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    sp = ImageDraw.Draw(scratches)
    for _ in range(int(rng.randint(5, 12) * ed["wear"])):
        a0 = rng.uniform(0, math.tau)
        arc = rng.uniform(0.1, 0.9)
        rad = r * rng.uniform(0.4, 0.95)
        sp.arc((size / 2 - rad, size / 2 - rad, size / 2 + rad, size / 2 + rad),
               math.degrees(a0), math.degrees(a0 + arc),
               fill=(255, 255, 255, rng.randint(18, 40)), width=1)
    disc = Image.alpha_composite(disc, scratches)

    # No sheen on the disc. A vinyl record does catch the light in a band across it,
    # but a *painted-on* one does not move when the record turns: it sits still while
    # the grooves rotate under it, which reads as a smear on the screen rather than as
    # light on a record. The grooves and the wear carry it.

    edge = Image.new("L", (size, size), 0)
    ImageDraw.Draw(edge).ellipse((0, 0, size - 1, size - 1), fill=255)
    disc.putalpha(ImageChops.darker(disc.getchannel("A"),
                                    edge.filter(ImageFilter.GaussianBlur(size / 900))))
    return disc


# ---------------------------------------------------------------- the still
def render(cover: pathlib.Path, colour: tuple[int, int, int], seed: str,
           size: int = CANVAS) -> Image.Image:
    """Jacket and disc as one picture, for everywhere that is not the player."""
    jacket_px = int(size * JACKET)
    face = render_jacket(cover, seed, jacket_px)

    scene = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    disc_px = int(jacket_px * 0.90)
    left = (size - jacket_px) // 2
    top = (size - jacket_px) // 2
    scene.alpha_composite(render_disc(cover, colour, seed, disc_px),
                          (left + int(jacket_px * DISC_PEEK),
                           top + (jacket_px - disc_px) // 2 + int(jacket_px * 0.03)))

    cast = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(cast).rectangle(
        (left + jacket_px * 0.55, top - 6, left + jacket_px + 8, top + jacket_px + 8),
        fill=(0, 0, 0, 120))
    scene = Image.alpha_composite(scene, cast.filter(ImageFilter.GaussianBlur(size / 60)))
    scene.alpha_composite(face, (left, top))

    turn = size * TURN
    coeffs = _perspective_coeffs(
        [(0, 0), (size, turn * 0.55), (size, size - turn * 0.55), (0, size)],
        [(0, 0), (size, 0), (size, size), (0, size)],
    )
    scene = scene.transform((size, size), Image.PERSPECTIVE, coeffs, Image.BICUBIC)

    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow.putalpha(scene.getchannel("A").point(lambda a: int(a * 0.55)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(size / 45))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.alpha_composite(shadow, (int(size * 0.008), int(size * 0.02)))
    return Image.alpha_composite(out, scene)


# ---------------------------------------------------------------- cache
SIZES = {"lg": CANVAS, "sm": 320}


# Bumped whenever the drawing changes. The art is cached under the cover's hash, which
# does not change when the *renderer* does — so without this, a fix to how a record is
# drawn only reaches records nobody has looked at yet.
VERSION = 6


def path_for(root: pathlib.Path, sha: str, size: str, part: str = "sleeve") -> pathlib.Path:
    stem = sha if part == "sleeve" else f"{sha}-{part}"
    return root / "sleeves" / f"{stem}-{size}-v{VERSION}.webp"


def build(root: pathlib.Path, cover: pathlib.Path, sha: str,
          colour: tuple[int, int, int], part: str = "sleeve") -> pathlib.Path:
    out = path_for(root, sha, "lg", part)
    if out.exists():
        return out
    out.parent.mkdir(parents=True, exist_ok=True)
    if part == "jacket":
        art = render_jacket(cover, sha)
    elif part == "disc":
        art = render_disc(cover, colour, sha)
    else:
        art = render(cover, colour, sha)
    # WebP because it keeps the alpha the shadow needs at a tenth of PNG's size.
    art.save(out, "WEBP", quality=88, method=4)
    art.resize((SIZES["sm"], SIZES["sm"]), Image.LANCZOS).save(
        path_for(root, sha, "sm", part), "WEBP", quality=82, method=4)
    return out
