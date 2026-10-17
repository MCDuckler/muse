# A scan's skin lifted so dark clothes still read on stage (photos in a dim room):
#   skin_tone.py <skin.png> <skin.webp> [gamma]   (gamma < 1 lifts the mids, keeps the highlights)
import sys, numpy as np
from PIL import Image
src, dst = sys.argv[1], sys.argv[2]; g = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
a = np.asarray(Image.open(src).convert("RGB")).astype(np.float64) / 255
out = (a ** g * 255).clip(0, 255).astype(np.uint8)
Image.fromarray(out).save(dst, "WEBP", quality=88, method=6)
l = out.mean(2); m = l > 8
print("median lum", round(float(np.median(l[m])), 1), "->", dst)
