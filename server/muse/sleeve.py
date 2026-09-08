"""A record, not a JPEG.

The now-playing screen showed a flat square, which is what a file looks like — not what
a record looks like. This renders the cover as an actual sleeve: a 12" jacket turned a
few degrees, the disc showing at its edge, and the wear a record that has been played
picks up — ring wear from the disc pressing through, whitened corners, a crease, dust.

Rendered once per cover and cached on disk, so the app pays nothing per frame: it is a
picture. Every mark is seeded from the cover's own hash, so a record looks the same
every time you open it, and no two records look alike.
"""
from __future__ import annotations

import math
import pathlib
import random

from PIL import Image, ImageDraw, ImageFilter

CANVAS = 900               # generated size; the client scales it down
JACKET = 0.80              # jacket edge length as a fraction of the canvas
DISC_PEEK = 0.19           # how much of the disc shows past the jacket
TURN = 0.055               # how far the jacket is turned, as a fraction of its width


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


# ---------------------------------------------------------------- the record
def _disc(size: int, colour: tuple[int, int, int], rng: random.Random) -> Image.Image:
    """Black vinyl: grooves, a label, a highlight where the light runs across it."""
    disc = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pen = ImageDraw.Draw(disc)
    pen.ellipse((0, 0, size - 1, size - 1), fill=(16, 15, 17, 255))

    # Grooves. Drawn as thin rings of alternating lightness; at playback size they read
    # as the grain of the vinyl rather than as circles.
    for i in range(38):
        t = i / 38
        r = size * (0.30 + 0.195 * t)
        shade = 34 + int(16 * math.sin(i * 2.1))
        pen.ellipse((size / 2 - r, size / 2 - r, size / 2 + r, size / 2 + r),
                    outline=(shade, shade, shade + 2, 255), width=max(1, size // 900))

    label = size * 0.155
    pen.ellipse((size / 2 - label, size / 2 - label, size / 2 + label, size / 2 + label),
                fill=(*colour, 255))
    pen.ellipse((size / 2 - label, size / 2 - label, size / 2 + label, size / 2 + label),
                outline=(0, 0, 0, 90), width=max(2, size // 300))
    hole = size * 0.012
    pen.ellipse((size / 2 - hole, size / 2 - hole, size / 2 + hole, size / 2 + hole),
                fill=(30, 28, 30, 255))

    # A soft sheen across the top-left, the giveaway that a surface is glossy.
    sheen = Image.new("L", (size, size), 0)
    ImageDraw.Draw(sheen).polygon(
        [(0, size * 0.1), (size * 0.75, 0), (size, size * 0.28), (size * 0.2, size * 0.62)],
        fill=52)
    sheen = sheen.filter(ImageFilter.GaussianBlur(size / 26))
    gloss = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    gloss.putalpha(sheen)
    disc = Image.alpha_composite(disc, gloss)

    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size - 1, size - 1), fill=255)
    disc.putalpha(Image.composite(disc.getchannel("A"), Image.new("L", (size, size), 0), mask))
    del rng
    return disc


# ---------------------------------------------------------------- the jacket
def _wear(art: Image.Image, rng: random.Random) -> Image.Image:
    """Everything that happens to cardboard that has been pulled off a shelf for years.

    Kept deliberately faint. The point is that the eye reads "object" instead of
    "image"; anything strong enough to notice on its own is too strong.
    """
    size = art.size[0]
    light = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    dark = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    lp, dp = ImageDraw.Draw(light), ImageDraw.Draw(dark)

    # Ring wear: the disc inside has been pressing on the same circle for decades. It
    # lives on its own layer so it can be blurred into a halo — drawn sharp it reads as
    # a circle someone printed on the cover.
    ring = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    rp = ImageDraw.Draw(ring)
    ring_r = size * rng.uniform(0.345, 0.375)
    cx = size / 2 + rng.uniform(-0.015, 0.015) * size
    cy = size / 2 + rng.uniform(-0.015, 0.015) * size
    rp.ellipse((cx - ring_r, cy - ring_r, cx + ring_r, cy + ring_r),
               outline=(255, 255, 255, 20), width=int(size * 0.022))
    rp.ellipse((cx - ring_r * 1.02, cy - ring_r * 1.02,
                cx + ring_r * 1.02, cy + ring_r * 1.02),
               outline=(0, 0, 0, 14), width=int(size * 0.03))
    ring = ring.filter(ImageFilter.GaussianBlur(size / 110))

    # Whitened edges and bumped corners, where the cardboard has frayed to the paper.
    for i in range(4):
        corner = [(0, 0), (size, 0), (size, size), (0, size)][i]
        reach = size * rng.uniform(0.05, 0.13)
        lp.polygon([corner,
                    (corner[0] + (reach if corner[0] == 0 else -reach), corner[1]),
                    (corner[0], corner[1] + (reach if corner[1] == 0 else -reach))],
                   fill=(255, 255, 255, rng.randint(18, 38)))
    lp.rectangle((0, 0, size - 1, size - 1), outline=(255, 255, 255, 34),
                 width=max(2, size // 260))
    # The spine edge catches the light, which is what tells you it is a board and not
    # a printed square.
    lp.line([(1, 0), (1, size)], fill=(255, 255, 255, 70), width=max(2, size // 300))

    # One or two creases, running off a corner the way a real one does.
    for _ in range(rng.randint(1, 2)):
        x0, y0 = rng.choice([(0, 0), (size, 0), (size, size), (0, size)])
        x1 = rng.uniform(size * 0.35, size * 0.75)
        y1 = rng.uniform(size * 0.35, size * 0.75)
        dp.line([(x0, y0), (x1, y1)], fill=(0, 0, 0, 30), width=max(2, size // 300))
        lp.line([(x0 + 2, y0), (x1 + 2, y1)], fill=(255, 255, 255, 34),
                width=max(1, size // 400))

    # Scuffs and dust.
    for _ in range(rng.randint(14, 22)):
        x, y = rng.uniform(0, size), rng.uniform(0, size)
        angle, length = rng.uniform(0, math.pi), rng.uniform(size * 0.02, size * 0.13)
        lp.line([(x, y), (x + math.cos(angle) * length, y + math.sin(angle) * length)],
                fill=(255, 255, 255, rng.randint(16, 34)), width=1)
    for _ in range(rng.randint(90, 150)):
        x, y = rng.uniform(0, size), rng.uniform(0, size)
        r = rng.uniform(0.6, 2.0)
        speck = dp if rng.random() < 0.6 else lp
        speck.ellipse((x, y, x + r, y + r),
                      fill=(0, 0, 0, rng.randint(30, 70)) if speck is dp
                      else (255, 255, 255, rng.randint(30, 70)))

    worn = Image.alpha_composite(art.convert("RGBA"), ring)
    worn = Image.alpha_composite(worn, light.filter(ImageFilter.GaussianBlur(size / 400)))
    worn = Image.alpha_composite(worn, dark.filter(ImageFilter.GaussianBlur(size / 400)))

    # Paper grain. Built from our own seeded noise rather than PIL's effect_noise,
    # which draws from a generator we do not control — the same record would then wear
    # differently on every request.
    tile = 160
    grain = Image.frombytes(
        "L", (tile, tile), bytes(rng.getrandbits(8) for _ in range(tile * tile))
    ).resize((size, size), Image.BILINEAR)
    worn = Image.blend(worn, Image.merge("RGBA", (grain, grain, grain,
                                                  worn.getchannel("A"))), 0.035)
    # The plastic outer sleeve catches one narrow band of light. Wide and bright, it
    # just looks like fog over the artwork.
    sheen = Image.new("L", (size, size), 0)
    ImageDraw.Draw(sheen).polygon(
        [(0, size * 0.30), (size * 0.34, 0), (size * 0.52, 0), (0, size * 0.56)], fill=22)
    ImageDraw.Draw(sheen).polygon(
        [(size * 0.62, size), (size, size * 0.58), (size, size * 0.74),
         (size * 0.80, size)], fill=12)
    gloss = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    gloss.putalpha(sheen.filter(ImageFilter.GaussianBlur(size / 22)))
    return Image.alpha_composite(worn, gloss)


def render(cover: pathlib.Path, colour: tuple[int, int, int], seed: str,
           size: int = CANVAS) -> Image.Image:
    rng = random.Random(int(seed[:12], 16))
    jacket_px = int(size * JACKET)

    art = Image.open(cover).convert("RGB")
    w, h = art.size
    scale = jacket_px / min(w, h)
    art = art.resize((max(jacket_px, int(w * scale)), max(jacket_px, int(h * scale))),
                     Image.LANCZOS)
    w, h = art.size
    art = art.crop(((w - jacket_px) // 2, (h - jacket_px) // 2,
                    (w - jacket_px) // 2 + jacket_px, (h - jacket_px) // 2 + jacket_px))
    face = _wear(art, rng)

    # The disc sits behind the jacket, pulled out to the right.
    scene = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    disc_px = int(jacket_px * 0.90)
    left = (size - jacket_px) // 2
    top = (size - jacket_px) // 2
    # Nudged down as well as out: a disc that pokes above the jacket's receding top
    # corner reads as a black wedge, not as a record.
    scene.alpha_composite(_disc(disc_px, colour, rng),
                          (left + int(jacket_px * DISC_PEEK),
                           top + (jacket_px - disc_px) // 2 + int(jacket_px * 0.03)))

    # The jacket's own thickness: a sliver of board along the spine, and the shadow the
    # jacket casts onto the disc behind it.
    edge = max(3, int(jacket_px * 0.012))
    board = Image.new("RGBA", (edge, jacket_px), (24, 22, 24, 255))
    scene.alpha_composite(board, (left - edge, top))
    cast = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(cast).rectangle(
        (left + jacket_px * 0.55, top - 6, left + jacket_px + edge * 4, top + jacket_px + 8),
        fill=(0, 0, 0, 120))
    scene = Image.alpha_composite(scene, cast.filter(ImageFilter.GaussianBlur(size / 60)))
    scene.alpha_composite(face, (left, top))

    # Turn it a few degrees: the right edge recedes, which is what makes it read as an
    # object standing in space rather than a picture lying on the screen.
    turn = size * TURN
    coeffs = _perspective_coeffs(
        [(0, 0), (size, turn * 0.55), (size, size - turn * 0.55), (0, size)],
        [(0, 0), (size, 0), (size, size), (0, size)],
    )
    scene = scene.transform((size, size), Image.PERSPECTIVE, coeffs,
                            Image.BICUBIC)

    # A shadow on the floor, from the silhouette we ended up with.
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow.putalpha(scene.getchannel("A").point(lambda a: int(a * 0.55)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(size / 45))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.alpha_composite(shadow, (int(size * 0.008), int(size * 0.02)))
    return Image.alpha_composite(out, scene)


def path_for(root: pathlib.Path, sha: str, size: str) -> pathlib.Path:
    return root / "sleeves" / f"{sha}-{size}.webp"


SIZES = {"lg": CANVAS, "sm": 320}


def build(root: pathlib.Path, cover: pathlib.Path, sha: str,
          colour: tuple[int, int, int]) -> pathlib.Path:
    out = path_for(root, sha, "lg")
    if out.exists():
        return out
    out.parent.mkdir(parents=True, exist_ok=True)
    art = render(cover, colour, sha)
    # WebP because it keeps the alpha the shadow needs at a tenth of PNG's size.
    art.save(out, "WEBP", quality=88, method=4)
    art.resize((SIZES["sm"], SIZES["sm"]), Image.LANCZOS).save(
        path_for(root, sha, "sm"), "WEBP", quality=82, method=4)
    return out
