# Stick-figure contact sheets of the candidates: one row a move, a pose per beat, the
# dancer turned to face us. -> <dir>/sheets/sheet_NN.png
import numpy as np, json, sys, os
from PIL import Image, ImageDraw
d = sys.argv[1]; C = json.load(open(f"{d}/candidates.json")); os.makedirs(f"{d}/sheets", exist_ok=True)
B = json.load(open(f"{d}/beats.json"))
BONES = [("Hips","Spine"),("Spine","Chest"),("Chest","Neck"),("Neck","Head"),("Chest","Shoulder_L"),("Shoulder_L","UpperArm_L"),("UpperArm_L","LowerArm_L"),("LowerArm_L","Hand_L"),
         ("Chest","Shoulder_R"),("Shoulder_R","UpperArm_R"),("UpperArm_R","LowerArm_R"),("LowerArm_R","Hand_R"),("Hips","UpperLeg_L"),("UpperLeg_L","LowerLeg_L"),("LowerLeg_L","Foot_L"),("Foot_L","Toes_L"),
         ("Hips","UpperLeg_R"),("UpperLeg_R","LowerLeg_R"),("LowerLeg_R","Foot_R"),("Foot_R","Toes_R")]
cache = {}
CW, CH, PER = 70, 120, 24
for k in range(0, len(C), PER):
    rows = C[k:k + PER]
    im = Image.new("RGB", (190 + CW * 16, CH * len(rows)), (20, 20, 24)); g = ImageDraw.Draw(im)
    for r, m in enumerate(rows):
        if m["clip"] not in cache:
            z = np.load(f"{d}/joints/{m['clip']}.npz"); cache[m["clip"]] = (z["P"], list(z["names"]))
        P, N = cache[m["clip"]]; ix = {n: i for i, n in enumerate(N)}
        b = B[m["clip"]]["beats"]
        f0, f1 = m["f0"], m["f1"]
        side = (P[f0:f1, ix["UpperLeg_L"]] - P[f0:f1, ix["UpperLeg_R"]]).mean(0); side[2] = 0
        a = np.arctan2(side[1], side[0])
        R = np.array([[np.cos(-a), -np.sin(-a), 0], [np.sin(-a), np.cos(-a), 0], [0, 0, 1]])
        g.text((4, r * CH + 4), f"{k + r}: {m['clip']} b{m['beat']}x{m['beats']}", fill=(230, 230, 230))
        g.text((4, r * CH + 20), f"bpm {m['bpm']:.0f} en {m['energy']:.1f}", fill=(160, 160, 160))
        g.text((4, r * CH + 36), f"seam {m['seam']:.2f} trav {m['travel']:.1f}", fill=(160, 160, 160))
        # 16 poses: every half beat
        bs = b[m["beat"]:m["beat"] + m["beats"] + 1]
        times = [bs[j // 2] + (bs[j // 2 + 1] - bs[j // 2]) * (j % 2) / 2 for j in range(min(16, 2 * m["beats"]))]
        for j, t in enumerate(times):
            p = P[int(t)] @ R.T; p = p - np.array([p[ix["Hips"], 0], 0, 0])
            ox, oy = 190 + j * CW + CW / 2, r * CH + CH - 8
            s = CH / 2.1
            q = lambda n: (ox + p[ix[n], 0] * s, oy - p[ix[n], 2] * s)
            col = (255, 200, 90) if j % 2 == 0 else (120, 140, 200)
            for u, v in BONES: g.line([q(u), q(v)], fill=col, width=2)
            hx, hy = q("Head"); g.ellipse([hx - 5, hy - 10, hx + 5, hy], outline=col)
    im.save(f"{d}/sheets/sheet_{k // PER:02d}.png")
print("sheets", (len(C) + PER - 1) // PER)
