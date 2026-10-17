# Cut every capture into moves of 8 beats (4 where the take is short), on the
# strongest periodic accent; describe each (energy, stillness, travel, loop seam, how
# rhythmic) -> candidates.json. Curated by hand afterwards (picks.json).
import numpy as np, json, sys
d = sys.argv[1]; B = json.load(open(f"{d}/beats.json"))
cands = []
for c, info in B.items():
    b = np.array(info["beats"]); sp = np.array(info["speed"]); e = np.array(info["env"])
    z = np.load(f"{d}/joints/{c}.npz"); P = z["P"]; names = list(z["names"])
    hand = [names.index("Hand_L"), names.index("Hand_R")]; head = names.index("Head")
    for L in (8, 4):
        if len(b) < L + 1: continue
        if L == 4 and len(b) >= 17: continue          # long takes: 8-beat moves only
        acc = np.r_[0, np.abs(np.diff(sp))]
        phase = int(np.argmax([acc[b[k::L]].mean() for k in range(L)])) if len(b) > 2 * L else 0
        for s in range(phase, len(b) - L, L):
            f0, f1 = int(b[s]), int(b[s + L])
            seg = sp[f0:f1]
            iv = np.diff(b[s:s + L + 1])
            rel = P[f0:f1 + 1] - P[f0:f1 + 1, :1]
            cands.append(dict(clip=c, beat=int(s), beats=L, f0=f0, f1=f1, energy=float(seg.mean()),
                              still=float((seg < 0.6).mean()),
                              hands_up=float((P[f0:f1, hand, 2].max(1) > P[f0:f1, head, 2]).mean()),
                              travel=float(np.linalg.norm(P[f1, 0, :2] - P[f0, 0, :2])),
                              seam=float(np.linalg.norm(rel[-1] - rel[0], axis=1).mean()),
                              crouch=float(P[f0:f1, 0, 2].min()),
                              steady=float(iv.std() / iv.mean()),
                              sal=float(e[b[s:s + L]].mean() - e[((b[s:s + L] + b[s + 1:s + L + 1]) // 2)].mean()),
                              bpm=float(60 * 30 / np.mean(iv))))
ok = [m for m in cands if m["still"] < 0.3 and m["steady"] < 0.12]
ok.sort(key=lambda m: (m["clip"], m["beat"]))
print(len(cands), "candidates", len(ok), "usable")
for m in ok:
    print(f'{m["clip"]:11s} b{m["beat"]:3d}x{m["beats"]} bpm {m["bpm"]:5.1f} en {m["energy"]:5.1f} still {m["still"]:.2f} up {m["hands_up"]:.2f} '
          f'trav {m["travel"]:.2f} seam {m["seam"]:.2f} sal {m["sal"]:4.1f} steady {m["steady"]:.2f} hipmin {m["crouch"]:.2f}')
json.dump(ok, open(f"{d}/candidates.json", "w"), indent=1)
