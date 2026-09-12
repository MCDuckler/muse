#!/usr/bin/env python3
"""Put the server's current icon into the app.

The web app asks the server what its icon is, so changing it changes everywhere the
browser looks. An installed Android app cannot do that — its launcher icon is inside
the APK — so the icon has to be baked in at build time instead, and this is what bakes
it. Run by publish.sh before an APK is built, so the icon on a phone's home screen is
the icon the server is serving and not whatever was in the repo months ago.

    python3 deploy/bake_icon.py [https://your.server]
"""
from __future__ import annotations

import io
import pathlib
import sys
import urllib.request

from PIL import Image

BASE = sys.argv[1] if len(sys.argv) > 1 else "https://158-69-192-169.nip.io"
ROOT = pathlib.Path(__file__).resolve().parents[1] / "app"

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


def main() -> int:
    try:
        master = fetch(1024)
    except Exception as e:
        print(f"   (could not read the server's icon: {e})")
        return 0                      # never hold up a build over this

    for folder, size in ANDROID.items():
        out = ROOT / "android/app/src/main/res" / folder / "ic_launcher.png"
        master.resize((size, size), Image.LANCZOS).save(out, optimize=True)

    for name, size in WEB.items():
        out = ROOT / "web" / name
        master.resize((size, size), Image.LANCZOS).save(out, optimize=True)

    # Maskable: a launcher crops it to whatever shape it likes, so the picture sits in
    # the middle 80% with its own darkness around it.
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

    print(f"   icon baked in from {BASE}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
