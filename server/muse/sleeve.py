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

    A shelf of records is not a shelf of identical objects: some are near mint, some
    have been carried to parties for thirty years, one has a corner punched out because
    a distributor wrote it off. The hash decides which one is yours.
    """
    rng = random.Random(int(seed[:12], 16))
    condition = rng.choices(["mint", "played", "beat"], weights=[3, 5, 2])[0]
    return {
        "rng": rng,
        "condition": condition,
        "wear": {"mint": 0.35, "played": 1.0, "beat": 1.7}[condition],
        "gloss": rng.random() < 0.45,          # laminated front, or matte board
        "cut_out": condition != "mint" and rng.random() < 0.14,
        "sticker": rng.random() < 0.22,
        "border": rng.random() < 0.30,         # print stops short of the edge
        "foxing": condition == "beat" and rng.random() < 0.6,
        "hue": rng.uniform(-0.02, 0.02),
    }


# ---------------------------------------------------------------- the jacket
def _board(size: int, rng: random.Random) -> Image.Image:
    """Bare cardboard: kraft-ish, with fibre running through it."""
    base = Image.new("RGB", (size, size), (206, 197, 182))
    tile = 200
    fibre = Image.frombytes(
        "L", (tile, tile), bytes(rng.getrandbits(8) for _ in range(tile * tile))
    ).resize((size, size), Image.BILINEAR).filter(ImageFilter.GaussianBlur(size / 700))
    return Image.blend(base, Image.merge("RGB", (fibre, fibre, fibre)), 0.18)


def _edge_mask(size: int, ed: dict) -> Image.Image:
    """Where the board shows through the print: edges and corners, unevenly.

    A straight white line around the artwork looks like a border someone designed. Real
    edge wear is ragged, heavier at the corners, and skips whole stretches.
    """
    rng = ed["rng"]
    mask = Image.new("L", (size, size), 0)
    pen = ImageDraw.Draw(mask)
    band = max(2, int(size * 0.008 * ed["wear"]))

    for side in range(4):
        x = 0.0
        while x < size:
            run = rng.uniform(size * 0.02, size * 0.18)
            if rng.random() < 0.72:
                thick = band * rng.uniform(0.4, 1.6)
                box = {
                    0: (x, 0, x + run, thick),
                    1: (size - thick, x, size, x + run),
                    2: (x, size - thick, x + run, size),
                    3: (0, x, thick, x + run),
                }[side]
                pen.rectangle(box, fill=rng.randint(120, 235))
            x += run

    for corner in ((0, 0), (size, 0), (size, size), (0, size)):
        reach = size * rng.uniform(0.03, 0.09) * ed["wear"]
        pen.polygon([corner,
                     (corner[0] + (reach if corner[0] == 0 else -reach), corner[1]),
                     (corner[0], corner[1] + (reach if corner[1] == 0 else -reach))],
                    fill=rng.randint(150, 255))
    return mask.filter(ImageFilter.GaussianBlur(size / 500))


def _wear_layers(size: int, ed: dict) -> tuple[Image.Image, Image.Image]:
    """Ring wear, creases, scuffs, dust — as one light layer and one dark one."""
    rng, wear = ed["rng"], ed["wear"]
    light = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    dark = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    lp, dp = ImageDraw.Draw(light), ImageDraw.Draw(dark)

    # Ring wear on its own layer so it can be blurred into a halo; drawn sharp it reads
    # as a circle someone printed on the cover.
    ring = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    rp = ImageDraw.Draw(ring)
    r = size * rng.uniform(0.345, 0.375)
    cx = size / 2 + rng.uniform(-0.015, 0.015) * size
    cy = size / 2 + rng.uniform(-0.015, 0.015) * size
    rp.ellipse((cx - r, cy - r, cx + r, cy + r),
               outline=(255, 255, 255, int(20 * wear)), width=int(size * 0.022))
    rp.ellipse((cx - r * 1.02, cy - r * 1.02, cx + r * 1.02, cy + r * 1.02),
               outline=(0, 0, 0, int(14 * wear)), width=int(size * 0.03))
    ring = ring.filter(ImageFilter.GaussianBlur(size / 110))

    # The seam where the jacket is folded, and the shadow inside the opening.
    dp.line([(size * 0.018, 0), (size * 0.018, size)], fill=(0, 0, 0, 34),
            width=max(2, size // 300))
    lp.line([(size * 0.026, 0), (size * 0.026, size)], fill=(255, 255, 255, 26),
            width=max(1, size // 450))

    for _ in range(rng.randint(1, 3) if wear > 0.5 else 0):
        x0, y0 = rng.choice([(0, 0), (size, 0), (size, size), (0, size)])
        x1, y1 = rng.uniform(size * 0.3, size * 0.8), rng.uniform(size * 0.3, size * 0.8)
        dp.line([(x0, y0), (x1, y1)], fill=(0, 0, 0, int(30 * wear)),
                width=max(2, size // 300))
        lp.line([(x0 + 2, y0), (x1 + 2, y1)], fill=(255, 255, 255, int(34 * wear)),
                width=max(1, size // 400))

    for _ in range(int(rng.randint(14, 22) * wear)):
        x, y = rng.uniform(0, size), rng.uniform(0, size)
        a, length = rng.uniform(0, math.pi), rng.uniform(size * 0.02, size * 0.13)
        lp.line([(x, y), (x + math.cos(a) * length, y + math.sin(a) * length)],
                fill=(255, 255, 255, rng.randint(16, 34)), width=1)

    for _ in range(int(rng.randint(90, 150) * wear)):
        x, y = rng.uniform(0, size), rng.uniform(0, size)
        rad = rng.uniform(0.6, 2.0)
        speck = dp if rng.random() < 0.6 else lp
        speck.ellipse((x, y, x + rad, y + rad),
                      fill=(0, 0, 0, rng.randint(30, 70)) if speck is dp
                      else (255, 255, 255, rng.randint(30, 70)))

    if ed["foxing"]:                       # the brown age spots old board grows
        for _ in range(rng.randint(6, 14)):
            x, y = rng.uniform(0, size), rng.uniform(0, size)
            rad = rng.uniform(size * 0.004, size * 0.016)
            dp.ellipse((x - rad, y - rad, x + rad, y + rad), fill=(96, 68, 30, 40))

    return Image.alpha_composite(ring, light.filter(
        ImageFilter.GaussianBlur(size / 400))), dark.filter(
        ImageFilter.GaussianBlur(size / 400))


def render_jacket(cover: pathlib.Path, seed: str, size: int = CANVAS) -> Image.Image:
    """The cardboard jacket, face on, with transparent surroundings.

    Square and centred so the client can rotate it about any axis and still have it sit
    where it expects. The bottom strip is the thickness of the board, which is what you
    see when the jacket tips up.
    """
    ed = edition(seed)
    rng = ed["rng"]

    art = Image.open(cover).convert("RGB")
    w, h = art.size
    scale = size / min(w, h)
    art = art.resize((max(size, int(w * scale)), max(size, int(h * scale))), Image.LANCZOS)
    w, h = art.size
    art = art.crop(((w - size) // 2, (h - size) // 2,
                    (w - size) // 2 + size, (h - size) // 2 + size))

    board = _board(size, rng)
    if ed["border"]:
        # Some pressings print the front onto a panel glued to the board, leaving a
        # margin of bare card all the way round.
        inset = int(size * rng.uniform(0.012, 0.025))
        panel = art.resize((size - inset * 2, size - inset * 2), Image.LANCZOS)
        art = board.copy()
        art.paste(panel, (inset, inset))

    face = Image.composite(board, art, _edge_mask(size, ed)).convert("RGBA")

    light, dark = _wear_layers(size, ed)
    face = Image.alpha_composite(face, light)
    face = Image.alpha_composite(face, dark)

    # Paper grain, from our own seeded noise: PIL's effect_noise draws from a generator
    # we do not control, so the same record would wear differently on every request.
    tile = 160
    grain = Image.frombytes(
        "L", (tile, tile), bytes(rng.getrandbits(8) for _ in range(tile * tile))
    ).resize((size, size), Image.BILINEAR)
    face = Image.blend(face, Image.merge("RGBA", (grain, grain, grain,
                                                  face.getchannel("A"))), 0.035)

    if ed["gloss"]:
        sheen = Image.new("L", (size, size), 0)
        ImageDraw.Draw(sheen).polygon(
            [(0, size * 0.30), (size * 0.34, 0), (size * 0.52, 0), (0, size * 0.56)], fill=24)
        ImageDraw.Draw(sheen).polygon(
            [(size * 0.62, size), (size, size * 0.58), (size, size * 0.74),
             (size * 0.80, size)], fill=13)
        gloss = Image.new("RGBA", (size, size), (255, 255, 255, 0))
        gloss.putalpha(sheen.filter(ImageFilter.GaussianBlur(size / 22)))
        face = Image.alpha_composite(face, gloss)

    if ed["sticker"]:
        # A price sticker someone half peeled off, in the corner shops always use.
        sw, sh = int(size * rng.uniform(0.10, 0.15)), int(size * rng.uniform(0.05, 0.07))
        sx, sy = int(size * rng.uniform(0.04, 0.1)), int(size * rng.uniform(0.04, 0.1))
        sticker = Image.new("RGBA", (sw, sh), (246, 242, 230, 220))
        ImageDraw.Draw(sticker).line([(sw * 0.15, sh * 0.55), (sw * 0.85, sh * 0.55)],
                                     fill=(70, 66, 62, 150), width=max(2, sh // 8))
        sticker = sticker.rotate(rng.uniform(-6, 6), expand=True, resample=Image.BICUBIC)
        face.alpha_composite(sticker, (sx, sy))

    if ed["cut_out"]:
        # A hole drilled through the corner: this copy was written off as unsellable.
        hole = Image.new("L", (size, size), 255)
        hx = size * rng.choice([0.06, 0.94])
        hy = size * rng.uniform(0.06, 0.2)
        rad = size * 0.022
        ImageDraw.Draw(hole).ellipse((hx - rad, hy - rad, hx + rad, hy + rad), fill=0)
        face.putalpha(ImageChops.darker(face.getchannel("A"), hole))

    # Softened corners and the board's own thickness along the bottom edge.
    corners = Image.new("L", (size, size), 0)
    ImageDraw.Draw(corners).rounded_rectangle(
        (0, 0, size - 1, size - 1), radius=int(size * 0.012), fill=255)
    face.putalpha(ImageChops.darker(face.getchannel("A"), corners))

    thickness = max(3, int(size * 0.014))
    out = Image.new("RGBA", (size, size + thickness), (0, 0, 0, 0))
    spine = Image.new("RGBA", (size, thickness), (72, 66, 60, 255))
    ImageDraw.Draw(spine).line([(0, 0), (size, 0)], fill=(150, 142, 130, 255), width=1)
    out.alpha_composite(spine, (0, size - 1))
    out.alpha_composite(face, (0, 0))
    return out.resize((size, size), Image.LANCZOS)


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

    sheen = Image.new("L", (size, size), 0)
    ImageDraw.Draw(sheen).polygon(
        [(0, size * 0.14), (size * 0.72, 0), (size, size * 0.3), (size * 0.16, size * 0.66)],
        fill=46)
    gloss = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    gloss.putalpha(sheen.filter(ImageFilter.GaussianBlur(size / 26)))
    disc = Image.alpha_composite(disc, gloss)

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


def path_for(root: pathlib.Path, sha: str, size: str, part: str = "sleeve") -> pathlib.Path:
    stem = sha if part == "sleeve" else f"{sha}-{part}"
    return root / "sleeves" / f"{stem}-{size}.webp"


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
