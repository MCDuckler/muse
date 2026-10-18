# Duets: two people captured dancing together (CMU 60/61 the same salsa couple, take for
# take; 18/19 and 20/21 a chicken dance side by side). Every 8-beat move of the first
# one's take (candidates.json) with the partner's take over the same frames, the two
# put back where they stood (each capture's joints are scaled by its own legs:
# bvh_joints.py keeps the leg), and how well it works as a loop for two: how far apart
# they get, the partner's seam, how far the couple travels -> duet_candidates.json, and
# stick-figure sheets of them (sheets/duet_NN.png: the lead yellow, the partner blue).
# The ones chosen go in duets.json: [{"a", "b", "beat", "beats", "style"}].
#   python dance_duets.py <dir>
import numpy as np, json, sys, os
from PIL import Image, ImageDraw

PAIRS = [(f"60_{k:02d}", f"61_{k:02d}", "latin") for k in range(1, 16)] + [("18_15", "19_15", "party"), ("20_01", "21_01", "party")]
d = sys.argv[1]
B = json.load(open(f"{d}/beats.json"))
C = json.load(open(f"{d}/candidates.json"))
os.makedirs(f"{d}/sheets", exist_ok=True)


def load(c):
    z = np.load(f"{d}/joints/{c}.npz")
    return z["P"] * float(z["leg"]), list(z["names"]), float(z["leg"])


def pair_frame(Pa, Pb, ix, f0, f1):
    """Turn that lays the couple across the picture (the lead on the left), facing us on
    average, and their middle: world xy -> pair xy."""
    ha, hb = Pa[f0:f1, ix["Hips"], :2], Pb[f0:f1, ix["Hips"], :2]
    axis = (hb - ha).mean(0)
    face = 0
    for P in (Pa, Pb):
        side = (P[f0:f1, ix["UpperLeg_L"]] - P[f0:f1, ix["UpperLeg_R"]])[:, :2].mean(0)
        face += np.array([side[1], -side[0]]) / (np.linalg.norm(side) + 1e-9)   # facing = side x up
    a = np.arctan2(axis[1], axis[0]) if np.linalg.norm(axis) > 0.25 else np.arctan2(-face[0], face[1]) - np.pi / 2
    R = np.array([[np.cos(-a), -np.sin(-a)], [np.sin(-a), np.cos(-a)]])
    if (R @ face)[1] > 0:                      # facing away: turn round, the partner on the left then
        R = -R
    mid = (np.r_[ha, hb]).mean(0)
    return R, mid


out = []
for a, b, style in PAIRS:
    if not os.path.exists(f"{d}/joints/{a}.npz") or a not in B: continue
    Pa, names, la = load(a); Pb, _, lb = load(b)
    k = 0.85 / ((la + lb) / 2)
    Pa, Pb = Pa * k, Pb * k
    n = min(len(Pa), len(Pb)); ix = {m: i for i, m in enumerate(names)}
    for m in C:
        if m["clip"] != a or m["beats"] != 8 or m["f1"] >= n: continue
        f0, f1 = m["f0"], m["f1"]
        dist = np.linalg.norm(Pa[f0:f1 + 1, 0, :2] - Pb[f0:f1 + 1, 0, :2], axis=1)
        relb = Pb[f0:f1 + 1] - Pb[f0:f1 + 1, :1]
        mid0 = (Pa[f0, 0, :2] + Pb[f0, 0, :2]) / 2; mid1 = (Pa[f1, 0, :2] + Pb[f1, 0, :2]) / 2
        spb = np.linalg.norm(np.diff(Pb[f0:f1 + 1, :, :], axis=0), axis=2).mean() * 30
        out.append(dict(a=a, b=b, style=style, beat=m["beat"], beats=8, f0=f0, f1=f1, bpm=m["bpm"], energy=m["energy"],
                        energy_b=float(spb), seam_a=m["seam"], seam_b=float(np.linalg.norm(relb[-1] - relb[0], axis=1).mean()),
                        dist=float(np.median(dist)), dmax=float(dist.max()), travel=float(np.linalg.norm(mid1 - mid0)),
                        legs=[la, lb]))
ok = [m for m in out if m["dmax"] < 1.9 and m["seam_a"] < 0.35 and m["seam_b"] < 0.35 and m["travel"] < 1.2]
print(len(out), "duet candidates", len(ok), "usable")
json.dump(ok, open(f"{d}/duet_candidates.json", "w"), indent=1)

BONES = [("Hips","Spine"),("Spine","Chest"),("Chest","Neck"),("Neck","Head"),("Chest","Shoulder_L"),("Shoulder_L","UpperArm_L"),("UpperArm_L","LowerArm_L"),("LowerArm_L","Hand_L"),
         ("Chest","Shoulder_R"),("Shoulder_R","UpperArm_R"),("UpperArm_R","LowerArm_R"),("LowerArm_R","Hand_R"),("Hips","UpperLeg_L"),("UpperLeg_L","LowerLeg_L"),("LowerLeg_L","Foot_L"),("Foot_L","Toes_L"),
         ("Hips","UpperLeg_R"),("UpperLeg_R","LowerLeg_R"),("LowerLeg_R","Foot_R"),("Foot_R","Toes_R")]
CW, CH, PER = 120, 130, 20
cache = {}
for s in range(0, len(ok), PER):
    rows = ok[s:s + PER]
    im = Image.new("RGB", (200 + CW * 16, CH * len(rows)), (20, 20, 24)); g = ImageDraw.Draw(im)
    for r, m in enumerate(rows):
        for c in (m["a"], m["b"]):
            if c not in cache: cache[c] = load(c)
        k = 0.85 / (sum(m["legs"]) / 2)
        Pa, names, _ = cache[m["a"]]; Pb = cache[m["b"]][0]; Pa, Pb = Pa * k, Pb * k
        ix = {x: i for i, x in enumerate(names)}
        R, mid = pair_frame(Pa, Pb, ix, m["f0"], m["f1"])
        g.text((4, r * CH + 4), f"{s + r}: {m['a']}+{m['b']} b{m['beat']}", fill=(230, 230, 230))
        g.text((4, r * CH + 20), f"bpm {m['bpm']:.0f} en {m['energy']:.0f}/{m['energy_b']:.1f}", fill=(160, 160, 160))
        g.text((4, r * CH + 36), f"dist {m['dist']:.2f}-{m['dmax']:.2f} trav {m['travel']:.2f}", fill=(160, 160, 160))
        g.text((4, r * CH + 52), f"seam {m['seam_a']:.2f}/{m['seam_b']:.2f}", fill=(160, 160, 160))
        bs = B[m["a"]]["beats"][m["beat"]:m["beat"] + 9]
        for j in range(16):
            t = int(bs[j // 2] + (bs[j // 2 + 1] - bs[j // 2]) * (j % 2) / 2)
            ox, oy = 200 + j * CW + CW / 2, r * CH + CH - 8
            sc = CH / 2.3
            for P, col in ((Pa, (255, 200, 90)), (Pb, (110, 170, 255))):
                p = P[t].copy(); p[:, :2] = (p[:, :2] - mid) @ R.T
                q = lambda n: (ox + p[ix[n], 0] * sc, oy - p[ix[n], 2] * sc)
                for u, v in BONES: g.line([q(u), q(v)], fill=col, width=2)
                hx, hy = q("Head"); g.ellipse([hx - 4, hy - 9, hx + 4, hy - 1], outline=col)
    im.save(f"{d}/sheets/duet_{s // PER:02d}.png")
print("sheets", (len(ok) + PER - 1) // PER)
