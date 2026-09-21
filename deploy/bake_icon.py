#!/usr/bin/env python3
"""Put the server's current icon into the app.

The web app asks the server what its icon is, so changing it changes everywhere the
browser looks. An installed Android app cannot do that — its launcher icon is inside
the APK — so the icon has to be baked in at build time instead, and this is what bakes
it. Run by publish.sh before an APK is built, so the icon on a phone's home screen is
the icon the server is serving and not whatever was in the repo months ago.

    python3 deploy/bake_icon.py [https://your.server]
    python3 deploy/bake_icon.py --from path/to/icon.png     # no server needed
"""
from __future__ import annotations

import io
import json
import pathlib
import sys
import urllib.request

from PIL import Image, ImageChops, ImageStat

ARGS = sys.argv[1:]
LOCAL = ARGS[ARGS.index("--from") + 1] if "--from" in ARGS else None
BASE = next((a for a in ARGS if a.startswith("http")), "https://89-58-49-140.nip.io")
ROOT = pathlib.Path(__file__).resolve().parents[1] / "app"

# The disco ball, drawn for the places a photograph cannot go on its own: the launcher's
# foreground layer with the red kept around it, and a stencil for the status bar and
# for Android's themed icons. Used only while the ball is the icon in use — anything
# else an admin puts up gets the generic treatment below, worked out from the picture.
BRAND = pathlib.Path(__file__).resolve().parent / "brand"
SHIPPED = pathlib.Path(__file__).resolve().parents[1] / "server/muse/assets/app_icon.png"
BRAND_RED = (232, 51, 40)

# The launcher's layers are 108dp, of which a mask shows at most the middle 72.
ADAPTIVE = {
    "mipmap-mdpi": 108, "mipmap-hdpi": 162, "mipmap-xhdpi": 216,
    "mipmap-xxhdpi": 324, "mipmap-xxxhdpi": 432,
}

# Every size the app ships, and where it goes.
ANDROID = {
    "mipmap-mdpi": 48, "mipmap-hdpi": 72, "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144, "mipmap-xxxhdpi": 192,
}
WEB = {"icons/Icon-192.png": 192, "icons/Icon-512.png": 512,
       "favicon.png": 32, "apple-touch-icon.png": 180}


def fetch(size: int) -> Image.Image:
    with urllib.request.urlopen(f"{BASE}/icon?size={size}", timeout=30) as r:
        return Image.open(io.BytesIO(r.read())).convert("RGB")


def is_brand(master: Image.Image) -> bool:
    """Whether the icon in use is the disco ball — compared by eye rather than by
    bytes, because the server re-encodes whatever it is given."""
    try:
        shipped = Image.open(SHIPPED).convert("RGB").resize((64, 64), Image.LANCZOS)
    except OSError:
        return False
    here = master.resize((64, 64), Image.LANCZOS)
    diff = ImageChops.difference(shipped, here).convert("L")
    return ImageStat.Stat(diff).mean[0] < 6


def adaptive(master: Image.Image) -> None:
    """The launcher icon as layers: a flat colour behind, a picture in front, and a
    one-colour version for the phones that tint every icon to match the wallpaper.

    Without these a modern Android launcher takes the square picture, shrinks it and
    sets it on a white disc of its own — which, for a red icon, is a red square in a
    white circle."""
    res = ROOT / "android/app/src/main/res"
    brand = is_brand(master)
    if brand:
        ground = BRAND_RED
        front = Image.open(BRAND / "ball_on_red.png").convert("RGBA")
        front_share = 0.58          # of the 108dp layer: a ring of red inside any mask
        mono = Image.open(BRAND / "stencil.png").convert("RGBA")
    else:
        corners = [master.getpixel(p) for p in [(8, 8), (1015, 8), (8, 1015), (1015, 1015)]]
        ground = tuple(sum(c[i] for c in corners) // 4 for i in range(3))
        front = master.convert("RGBA")
        front_share = 72 / 108      # the whole picture, filling what a mask can show
        mono = None
    for folder, size in ADAPTIVE.items():
        out = res / folder
        out.mkdir(parents=True, exist_ok=True)
        inner = round(size * front_share)
        layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        layer.paste(front.resize((inner, inner), Image.LANCZOS),
                    ((size - inner) // 2, (size - inner) // 2))
        layer.save(out / "ic_launcher_foreground.png", optimize=True)
        if mono is not None:
            m = Image.new("RGBA", (size, size), (0, 0, 0, 0))
            small = round(size * 0.50)
            m.paste(mono.resize((small, small), Image.LANCZOS),
                    ((size - small) // 2, (size - small) // 2))
            m.save(out / "ic_launcher_monochrome.png", optimize=True)
        else:
            # The picture's own shape, if it has one, stands in for a drawn stencil.
            layer.save(out / "ic_launcher_monochrome.png", optimize=True)
    (res / "values").mkdir(exist_ok=True)
    (res / "values/ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        f'    <color name="ic_launcher_background">#{ground[0]:02X}{ground[1]:02X}{ground[2]:02X}</color>\n'
        '</resources>\n')


def main() -> int:
    try:
        master = (Image.open(LOCAL).convert("RGB").resize((1024, 1024), Image.LANCZOS)
                  if LOCAL else fetch(1024))
    except Exception as e:
        print(f"   (could not read the icon: {e})")
        return 0                      # never hold up a build over this

    for folder, size in ANDROID.items():
        out = ROOT / "android/app/src/main/res" / folder / "ic_launcher.png"
        master.resize((size, size), Image.LANCZOS).save(out, optimize=True)

    for name, size in WEB.items():
        out = ROOT / "web" / name
        master.resize((size, size), Image.LANCZOS).save(out, optimize=True)

    # The iPhone's icons, every size its catalogue asks for.
    #
    # Read from Contents.json rather than listed here: the set Xcode wants has changed
    # twice in recent memory, and a list in this file would be a list that is wrong
    # after somebody opens the project in a newer Xcode. No alpha channel, because iOS
    # composites an icon with transparency onto black and calls it a design.
    icons = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    manifest = icons / "Contents.json"
    if manifest.exists():
        catalogue = json.loads(manifest.read_text())
        done: set[str] = set()
        for entry in catalogue.get("images", []):
            name = entry.get("filename")
            if not name or name in done:
                continue
            done.add(name)
            points = float(entry["size"].split("x")[0])
            scale = float(entry.get("scale", "1x").rstrip("x"))
            px = max(1, round(points * scale))
            master.resize((px, px), Image.LANCZOS).convert("RGB").save(
                icons / name, optimize=True)
        print(f"   iphone icons: {len(done)} sizes")

    # The little white one in the status bar.
    #
    # Android draws a notification's small icon as a stencil: it keeps the alpha and
    # throws the colours away. Handed a full-colour launcher icon it shows a white
    # blob, and on some builds refuses the notification altogether — which is a media
    # notification that never appears, a service that never reaches the foreground and
    # an app the system is then free to freeze the moment it leaves the screen.
    #
    # So: the icon's own shape, in white, with the background dropped. Anything that
    # is not close to the darkest corner of the picture is the bird.
    adaptive(master)

    if is_brand(master):
        white = Image.open(BRAND / "stencil.png").convert("RGBA")
        for folder, size in {"drawable-mdpi": 24, "drawable-hdpi": 36,
                             "drawable-xhdpi": 48, "drawable-xxhdpi": 72,
                             "drawable-xxxhdpi": 96}.items():
            out = ROOT / "android/app/src/main/res" / folder
            out.mkdir(parents=True, exist_ok=True)
            # A little inside the square, as the platform's own glyphs sit.
            canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
            inner = round(size * 0.84)
            canvas.paste(white.resize((inner, inner), Image.LANCZOS),
                         ((size - inner) // 2, (size - inner) // 2))
            canvas.save(out / "ic_stat_wetowl.png", optimize=True)
        maskable(master)
        print(f"   icon baked in from {LOCAL or BASE} (the disco ball)")
        return 0

    grey = master.convert("L")
    corners = [grey.getpixel(p) for p in
               [(8, 8), (1015, 8), (8, 1015), (1015, 1015)]]
    ground = sum(corners) // len(corners)
    # Whichever way round the picture is: a dark bird on a light ground keeps what is
    # darker than the ground, a light one on a dark ground keeps what is lighter.
    stencil = grey.point(
        (lambda v: 255 if v < ground - 28 else 0) if ground > 127
        else (lambda v: 255 if v > ground + 28 else 0))
    white = Image.new("RGBA", master.size, (255, 255, 255, 0))
    white.putalpha(stencil)
    for folder, size in {"drawable-mdpi": 24, "drawable-hdpi": 36,
                         "drawable-xhdpi": 48, "drawable-xxhdpi": 72,
                         "drawable-xxxhdpi": 96}.items():
        out = ROOT / "android/app/src/main/res" / folder
        out.mkdir(parents=True, exist_ok=True)
        white.resize((size, size), Image.LANCZOS).save(
            out / "ic_stat_wetowl.png", optimize=True)

    maskable(master)
    print(f"   icon baked in from {LOCAL or BASE}")
    return 0


def maskable(master: Image.Image) -> None:
    """For an installed web app: a launcher crops it to whatever shape it likes, so the
    picture sits in the middle 80%.

    The ball already has its red around it, and the red simply carries on to the edge.
    Anything else gets its own darkness around it."""
    if is_brand(master):
        ground = BRAND_RED
    else:
        corners = [master.crop(box).resize((1, 1), Image.LANCZOS).getpixel((0, 0))
                   for box in [(0, 0, 120, 120), (904, 0, 1024, 120),
                               (0, 904, 120, 1024), (904, 904, 1024, 1024)]]
        ground = tuple(sum(c[i] for c in corners) // 4 * 6 // 10 for i in range(3))
    for name, size in {"icons/Icon-maskable-192.png": 192,
                       "icons/Icon-maskable-512.png": 512}.items():
        canvas = Image.new("RGB", (size, size), ground)
        inner = int(size * 0.8)
        canvas.paste(master.resize((inner, inner), Image.LANCZOS),
                     ((size - inner) // 2, (size - inner) // 2))
        canvas.save(ROOT / "web" / name, optimize=True)


if __name__ == "__main__":
    raise SystemExit(main())
