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

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter

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


# ---------------------------------------------------------------- triangulation
def _circumcircle(a, b, c):
    """Centre and squared radius of the circle through three points."""
    ax, ay = a
    bx, by = b
    cx, cy = c
    d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
    if abs(d) < 1e-12:
        return None
    a2 = ax * ax + ay * ay
    b2 = bx * bx + by * by
    c2 = cx * cx + cy * cy
    ux = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
    uy = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
    return (ux, uy), (ux - ax) ** 2 + (uy - ay) ** 2


def _delaunay(points: list[tuple[float, float]]) -> list[tuple[int, int, int]]:
    """Bowyer-Watson, written out rather than imported.

    The whole faceting rests on this and it is forty lines; adding numpy or scipy to
    the image to avoid writing them would be a hundred megabytes for one function that
    runs once per record and then never again.
    """
    if len(points) < 3:
        return []
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    span = max(max(xs) - min(xs), max(ys) - min(ys)) or 1.0
    mx, my = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    # A triangle far enough out that every real point is inside it.
    big = span * 20
    pts = list(points) + [(mx - big, my - big), (mx + big, my - big), (mx, my + big)]
    n = len(points)
    tris = [(n, n + 1, n + 2)]
    circles = {tris[0]: _circumcircle(pts[n], pts[n + 1], pts[n + 2])}

    for i in range(n):
        px, py = pts[i]
        bad = []
        for tri in tris:
            circle = circles.get(tri)
            if circle is None:
                continue
            (cx, cy), r2 = circle
            if (px - cx) ** 2 + (py - cy) ** 2 <= r2:
                bad.append(tri)
        if not bad:
            continue

        # The hole those triangles leave: every edge that only one of them owns.
        seen: dict[tuple[int, int], int] = {}
        for a, b, c in bad:
            for edge in ((a, b), (b, c), (c, a)):
                key = (min(edge), max(edge))
                seen[key] = seen.get(key, 0) + 1
        for tri in bad:
            tris.remove(tri)
            circles.pop(tri, None)
        for (a, b), count in seen.items():
            if count != 1:
                continue
            tri = (a, b, i)
            circle = _circumcircle(pts[a], pts[b], pts[i])
            if circle is None:
                continue
            tris.append(tri)
            circles[tri] = circle

    return [t for t in tris if all(v < n for v in t)]


def _facet_points(art: Image.Image, size: int, count: int,
                  rng: random.Random) -> list[tuple[float, float]]:
    """Where the corners of the facets go.

    Denser where the picture has something in it. Scattering evenly gives an even mesh,
    which is a mosaic; putting more of them where the image changes is what makes the
    facets follow the artwork — a face keeps its features, a flat sky becomes two large
    planes.
    """
    grid = 48
    detail = (art.convert("L").resize((grid, grid), Image.BILINEAR)
              .filter(ImageFilter.FIND_EDGES))
    weights = list(detail.getdata())  # noqa: PIL deprecation lands in 14
    top = max(weights) or 1

    points = []
    # The frame first, so the facets reach the edges instead of leaving a ragged margin.
    edge_steps = max(6, int(count ** 0.5))
    for i in range(edge_steps):
        t = i / edge_steps
        jitter = rng.uniform(-0.4, 0.4) / edge_steps
        u = min(max(t + jitter, 0.0), 1.0) * size
        points += [(u, 0.0), (u, float(size)), (0.0, u), (float(size), u)]
    points += [(0.0, 0.0), (float(size), 0.0), (0.0, float(size)),
               (float(size), float(size))]

    cell = size / grid
    tries = 0
    while len(points) < count and tries < count * 40:
        tries += 1
        gx, gy = rng.randrange(grid), rng.randrange(grid)
        # Rejection sampling against the edge map, with a floor so empty areas still
        # get some structure rather than one enormous triangle.
        want = 0.18 + 0.82 * (weights[gy * grid + gx] / top)
        if rng.random() > want:
            continue
        points.append(((gx + rng.random()) * cell, (gy + rng.random()) * cell))
    return points


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
        "cut_out": condition != "mint" and rng.random() < 0.14,
        "sticker": rng.random() < 0.22,
        # Where the light comes from, per copy: two records lit identically look
        # printed, two lit differently look like objects on a shelf.
        "light": (rng.uniform(-0.75, -0.25), rng.uniform(-0.9, -0.45)),
    }


# ---------------------------------------------------------------- the jacket
def facet(art: Image.Image, size: int, ed: dict, count: int = 620,
          relief: float = 0.30) -> Image.Image:
    """The artwork, rebuilt out of flat triangles.

    Not a filter over the picture: the picture is thrown away and redrawn as a few
    hundred planes, each one a single colour taken from what was underneath it. That is
    what makes it read as something *rendered* rather than something photographed and
    then processed — and it is why the old version never worked, because a wash of
    scratches over a photograph is still a photograph.

    The facets are then lit. Every triangle is given a pretend tilt from its own
    position, and shaded against one light, so neighbouring planes separate the way
    they do on a faceted surface. It is a lie about geometry that does not exist, but
    it is a consistent one, which is all the eye is asking for.
    """
    rng = ed["rng"]
    # Drawn at twice the size and brought back down: PIL's polygon fill has no
    # anti-aliasing, and a mesh of hard-edged triangles at final size looks like a
    # rendering error rather than a rendering.
    work = size * 2
    art = art.resize((work, work), Image.LANCZOS)
    source = art.load()

    points = _facet_points(art, work, count, rng)
    out = Image.new("RGB", (work, work), (0, 0, 0))
    pen = ImageDraw.Draw(out)

    lx, ly = ed["light"]
    length = math.hypot(lx, ly, 1.0)
    lx, ly, lz = lx / length, ly / length, 1.0 / length

    for a, b, c in _delaunay(points):
        pa, pb, pc = points[a], points[b], points[c]
        cx = (pa[0] + pb[0] + pc[0]) / 3
        cy = (pa[1] + pb[1] + pc[1]) / 3
        px = min(work - 1, max(0, int(cx)))
        py = min(work - 1, max(0, int(cy)))
        r, g, bl = source[px, py][:3]

        # A tilt for this facet, from where it is rather than from anything real, so
        # the same record is lit the same way every time it is drawn.
        nx = math.sin(cx * 0.011 + cy * 0.006) * relief
        ny = math.cos(cy * 0.013 - cx * 0.005) * relief
        norm = math.hypot(nx, ny, 1.0)
        lambert = (nx * lx + ny * ly + lz) / norm
        shade = 0.72 + 0.46 * max(0.0, lambert)

        pen.polygon([pa, pb, pc], fill=(
            min(255, int(r * shade)),
            min(255, int(g * shade)),
            min(255, int(bl * shade)),
        ))
    return out.resize((size, size), Image.LANCZOS)


def _retro(face: Image.Image, size: int, ed: dict) -> Image.Image:
    """Old paper and old ink, without pretending to be a photograph of either.

    Three things, all of them flat: the colour pulled back and warmed the way a print
    ages, a vignette, and the grain of the stock. What is deliberately *not* here is
    the ring of bare cardboard the previous version composited round the edge of every
    cover — the "ugly grey border". Wear on a stylised object has to be stylised too,
    or it is a photograph of damage stuck to a drawing.
    """
    rng, wear = ed["rng"], ed["wear"]

    # Aged ink: less saturated, warmer, and never quite reaching black or white.
    faded = ImageEnhance.Color(face).enhance(0.82 - 0.12 * wear)
    faded = ImageEnhance.Contrast(faded).enhance(0.92)
    warm = Image.new("RGB", (size, size), (236, 214, 176))
    face = Image.blend(faded, warm, 0.06 + 0.05 * wear)

    # A vignette: the corners of a sleeve are handled most and darken first.
    #
    # Built small and scaled up rather than drawn at full size. Nested outlines at 900
    # pixels are 900-pixel-long hairlines — the ring pattern is visible as rings, which
    # is the same mistake as the border it replaced. At a fortieth of the size the same
    # steps are a pixel apart and the resize is the gradient.
    steps = 40
    small = Image.new("L", (steps, steps), 255)
    pen = ImageDraw.Draw(small)
    for i in range(steps // 2):
        t = i / (steps / 2)
        pen.rectangle((i, i, steps - 1 - i, steps - 1 - i),
                      outline=int(255 - 52 * wear * (1 - t) ** 2.2))
    shade = small.resize((size, size), Image.BICUBIC).filter(
        ImageFilter.GaussianBlur(size / 90))
    face = ImageChops.multiply(face, Image.merge("RGB", (shade, shade, shade)))

    # The stock itself. Seeded here rather than by PIL's own noise, so a record wears
    # the same way every time it is asked for.
    tile = 180
    grain = Image.frombytes(
        "L", (tile, tile), bytes(rng.getrandbits(8) for _ in range(tile * tile))
    ).resize((size, size), Image.BILINEAR)
    face = Image.blend(face, Image.merge("RGB", (grain, grain, grain)),
                       0.045 + 0.02 * wear)
    return face


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

    face = _retro(facet(art, size, ed), size, ed).convert("RGBA")

    # A crease or two: a soft band of shadow with a soft band of light beside it, which
    # is what a fold in card actually looks like. Drawn as hairlines it read as a
    # scratch on the screen rather than as a mark on an object — the same mistake, at
    # one pixel wide, as the border this render exists to be rid of.
    if ed["wear"] > 0.5:
        marks = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        mp = ImageDraw.Draw(marks)
        for _ in range(rng.randint(1, 2)):
            x0, y0 = rng.choice([(0, 0), (size, 0), (size, size), (0, size)])
            x1 = rng.uniform(size * 0.35, size * 0.75)
            y1 = rng.uniform(size * 0.35, size * 0.75)
            band = max(3, int(size * 0.012))
            mp.line([(x0, y0), (x1, y1)], fill=(0, 0, 0, int(20 * ed["wear"])),
                    width=band)
            mp.line([(x0 + band, y0), (x1 + band, y1)],
                    fill=(255, 255, 255, int(16 * ed["wear"])), width=band)
        face = Image.alpha_composite(
            face, marks.filter(ImageFilter.GaussianBlur(size / 160)))

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
VERSION = 3


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
