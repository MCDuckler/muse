"""Cover art for a playlist that has none of its own.

Spotify tiles the first four album covers in a 2×2 grid. That reads as four unrelated
squares in a box. This instead cuts the square into slanted bands, one album per band,
over a wash mixed from the covers' own colours — so a playlist gets a piece of art that
belongs to the music in it, and is still recognisably made of those records.

The image is a pure function of which covers are in it: the same playlist renders the
same picture, and the filename carries the signature so the client can cache it forever.
"""
from __future__ import annotations

import colorsys
import hashlib
import math
import pathlib

from PIL import Image, ImageDraw, ImageFilter

from . import db

SIZES = {"lg": 640, "sm": 160}
ANGLE_DEGREES = 24.0          # the tilt of the bands; shallow enough to stay readable
COVERS_PER_ART = 4


def _picks(playlist_id: int) -> list[dict]:
    """Up to four covers, spread across the playlist rather than taken off the front.

    The front of a long playlist is often four tracks from one record, which makes four
    near-identical bands. Spreading picks four albums that actually differ.
    """
    rows = db.all_(
        """select distinct on (c.sha256) c.sha256, c.path, c.color, i.pos
             from playlist_items i
             join tracks t on t.id = i.track_id
             join covers c on c.id = t.cover_id
            where i.playlist_id = %s
            order by c.sha256, i.pos""",
        (playlist_id,),
    )
    rows.sort(key=lambda r: r["pos"])
    if len(rows) <= COVERS_PER_ART:
        return rows
    step = len(rows) / COVERS_PER_ART
    return [rows[min(len(rows) - 1, int(i * step))] for i in range(COVERS_PER_ART)]


def signature(playlist_id: int, name: str) -> str:
    """Changes exactly when the picture would."""
    picks = _picks(playlist_id)
    material = "|".join(r["sha256"] for r in picks) or f"name:{name}"
    return hashlib.sha256(material.encode()).hexdigest()[:12]


def _wash(colours: list[str], seed: str) -> tuple[tuple[int, int, int], tuple[int, int, int]]:
    """Two colours for the background, from the covers when there are any."""
    def parse(c: str) -> tuple[float, float, float]:
        c = c.lstrip("#")
        return tuple(int(c[i:i + 2], 16) / 255 for i in (0, 2, 4))     # type: ignore

    if colours:
        hls = [colorsys.rgb_to_hls(*parse(c)) for c in colours if c]
    else:
        # No art at all: a deterministic pair from the name, so an empty playlist still
        # gets a cover of its own rather than a grey box.
        h = int(hashlib.sha256(seed.encode()).hexdigest()[:8], 16) / 0xFFFFFFFF
        hls = [(h, 0.42, 0.55), ((h + 0.12) % 1.0, 0.22, 0.5)]

    hls.sort(key=lambda x: x[0])
    first, last = hls[0], hls[-1]
    dark = colorsys.hls_to_rgb(first[0], min(0.34, max(0.16, first[2] * 0.5)), max(0.35, first[2]))
    light = colorsys.hls_to_rgb(last[0], min(0.62, max(0.34, last[1])), max(0.4, last[2]))
    return (tuple(int(v * 255) for v in dark),        # type: ignore
            tuple(int(v * 255) for v in light))       # type: ignore


def _gradient(size: int, a: tuple[int, int, int], b: tuple[int, int, int]) -> Image.Image:
    """A diagonal wash, drawn small and scaled up — cheaper than per-pixel, and the
    blur that comes with scaling is exactly what a gradient wants."""
    small = Image.new("RGB", (2, 2))
    small.putpixel((0, 0), a)
    small.putpixel((1, 0), tuple((x + y) // 2 for x, y in zip(a, b)))   # type: ignore
    small.putpixel((0, 1), tuple((x * 2 + y) // 3 for x, y in zip(a, b)))  # type: ignore
    small.putpixel((1, 1), b)
    return small.resize((size, size), Image.BICUBIC)


def _band_polygon(size: int, index: int, count: int) -> list[tuple[float, float]]:
    """One slanted band, cut across the square.

    The bands are parallel and tilted, so the seams run corner-ish to corner-ish and
    the square never reads as a grid. Offsets are computed along the horizontal axis and
    sheared vertically, which keeps every band the same visual width.
    """
    shear = math.tan(math.radians(ANGLE_DEGREES)) * size
    span = size + shear                      # extra width to cover the shear overhang
    left = -shear + span * index / count
    right = -shear + span * (index + 1) / count
    return [(left, 0), (right, 0), (right + shear, size), (left + shear, size)]


def _fitted(path: pathlib.Path, size: int) -> Image.Image:
    img = Image.open(path).convert("RGB")
    w, h = img.size
    scale = size / min(w, h)
    img = img.resize((max(size, int(w * scale)), max(size, int(h * scale))), Image.LANCZOS)
    w, h = img.size
    return img.crop(((w - size) // 2, (h - size) // 2,
                     (w - size) // 2 + size, (h - size) // 2 + size))


def render(playlist_id: int, name: str, size: int = 640) -> Image.Image:
    picks = _picks(playlist_id)
    dark, light = _wash([p["color"] for p in picks if p.get("color")], name)
    canvas = _gradient(size, dark, light)

    usable = [p for p in picks if pathlib.Path(p["path"]).exists()]
    count = len(usable)
    if not count:
        # Nothing to show yet. Draw the bands anyway, in the wash's own two tones, so an
        # empty playlist looks like a quiet member of the family rather than a blank.
        ghosts = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        pen = ImageDraw.Draw(ghosts)
        for i in range(4):
            shade = (255, 255, 255, 20) if i % 2 else (0, 0, 0, 28)
            pen.polygon(_band_polygon(size, i, 4), fill=shade)
        canvas = Image.alpha_composite(canvas.convert("RGBA"), ghosts).convert("RGB")
    if count:
        for i, pick in enumerate(usable):
            art = _fitted(pathlib.Path(pick["path"]), size)
            mask = Image.new("L", (size, size), 0)
            ImageDraw.Draw(mask).polygon(_band_polygon(size, i, count), fill=255)
            canvas.paste(art, (0, 0), mask)

        # Seams: a dark hairline with a light one beside it reads as separate panels
        # without the heavy borders that make a collage look like a table.
        seams = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        pen = ImageDraw.Draw(seams)
        for i in range(1, count):
            poly = _band_polygon(size, i, count)
            pen.line([poly[0], poly[3]], fill=(0, 0, 0, 90), width=max(2, size // 200))
            pen.line([(poly[0][0] + 1.5, poly[0][1]), (poly[3][0] + 1.5, poly[3][1])],
                     fill=(255, 255, 255, 60), width=max(1, size // 400))
        canvas = Image.alpha_composite(canvas.convert("RGBA"), seams).convert("RGB")

    # A corner-to-corner sheen and a soft vignette, so the flat bands get some depth.
    overlay = Image.new("L", (size, size), 0)
    ImageDraw.Draw(overlay).polygon(
        [(0, 0), (size, 0), (0, size)], fill=26 if count else 40)
    canvas = Image.composite(Image.new("RGB", (size, size), (255, 255, 255)),
                             canvas, overlay.filter(ImageFilter.GaussianBlur(size / 12)))
    vignette = Image.new("L", (size, size), 0)
    ImageDraw.Draw(vignette).ellipse((-size * 0.25, -size * 0.25,
                                      size * 1.25, size * 1.25), fill=255)
    return Image.composite(canvas, Image.new("RGB", (size, size), (12, 12, 14)),
                           vignette.filter(ImageFilter.GaussianBlur(size / 8)))


def path_for(root: pathlib.Path, playlist_id: int, sig: str, size: str) -> pathlib.Path:
    return root / "playlists" / f"{playlist_id}-{sig}-{size}.jpg"


def build(root: pathlib.Path, playlist_id: int, name: str, sig: str) -> pathlib.Path:
    """Render both sizes if they are not already on disk, and sweep up old versions."""
    out = path_for(root, playlist_id, sig, "lg")
    if out.exists():
        return out
    out.parent.mkdir(parents=True, exist_ok=True)
    big = render(playlist_id, name, SIZES["lg"])
    big.save(out, "JPEG", quality=88, optimize=True)
    big.resize((SIZES["sm"], SIZES["sm"]), Image.LANCZOS).save(
        path_for(root, playlist_id, sig, "sm"), "JPEG", quality=82, optimize=True)
    for stale in out.parent.glob(f"{playlist_id}-*.jpg"):
        if sig not in stale.name:
            stale.unlink(missing_ok=True)
    return out
