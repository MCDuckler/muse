# Check the 3D bank the way the app will draw it: FK, linear-blend skinning, a camera,
# painter's sort, flat per-triangle colour from the skin. -> check/<move>.png (8 beats)
import numpy as np, json, sys, struct
from PIL import Image, ImageDraw
d = sys.argv[1]; ids = sys.argv[2:]
J = json.load(open(f"{d}/dancer.json")); raw = open(f"{d}/dancer.bin", "rb").read(); mv = open(f"{d}/moves.bin", "rb").read()
skin = np.asarray(Image.open(f"{d}/skin.webp").convert("RGB")) / 255.0
m = J["meshes"][0]; n, nc, t, o = m["positions"], m["verts"], m["tris"], m["offset"]
def arr(dt, cnt, off): return np.frombuffer(raw, dt, cnt, off)
P = arr("<f4", n * 3, o).reshape(n, 3); o += n * 12
N = arr("<f4", n * 3, o).reshape(n, 3); o += n * 12
BI = arr("u1", n * 4, o).reshape(n, 4); o += n * 4
BW = arr("u1", n * 4, o).reshape(n, 4) / 255.0; o += n * 4
UVc = arr("<f4", nc * 2, o).reshape(nc, 2); o += nc * 8
SRC = arr("<u2", nc, o).astype(int); o += nc * 2
Tc = arr("<u2", t * 3, o).reshape(t, 3).astype(int)
T = SRC[Tc]
UV = np.zeros((n, 2)); UV[SRC] = UVc  # one skin coordinate per position, enough for a check
rest = [np.array(b["rest"]).reshape(4, 4) for b in J["bones"]]; par = [b["parent"] for b in J["bones"]]
nb = len(rest); inv = [np.linalg.inv(r) for r in rest]
rel = [np.eye(4) if p < 0 else inv[p] @ rest[i] for i, p in enumerate(par)]
def qm(q):
    w, x, y, z = q
    return np.array([[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)], [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)], [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]])
col = skin[(UV[:, 1] * 1023).clip(0, 1023).astype(int), (UV[:, 0] * 1023).clip(0, 1023).astype(int)]
SB = J["sample"]["bytes"]
for mid in ids:
    M = next(x for x in J["moves"] if x["id"] == mid)
    ims = []
    for beat in range(M["beats"]):
        j = beat * J["fpb"]; off = M["offset"] + j * SB
        q = np.array(struct.unpack_from(f"<{nb*4}h", mv, off)).reshape(nb, 4) / 32767; p = np.array(struct.unpack_from("<3h", mv, off + nb * 8)) / 1000
        G = []
        for i in range(nb):
            L = np.eye(4); L[:3, :3] = qm(q[i])
            if par[i] < 0: L[:3, 3] = p; G.append(L)
            else: G.append(G[par[i]] @ rel[i] @ L)
        S = np.stack([G[i] @ inv[i] for i in range(nb)])
        Mv = (S[BI] * BW[..., None, None]).sum(1)
        V = np.einsum("nij,nj->ni", Mv[:, :3, :3], P) + Mv[:, :3, 3]
        Nn = np.einsum("nij,nj->ni", Mv[:, :3, :3], N); Nn /= np.linalg.norm(Nn, axis=1, keepdims=True) + 1e-9
        # camera: in front (-Y), 22 deg round, 5 m off, looking at 1 m high
        yaw = np.radians(22); cam = np.array([5 * np.sin(yaw), -5 * np.cos(yaw), 1.2]); tgt = np.array([0, 0, 1.0])
        f = tgt - cam; f /= np.linalg.norm(f); r = np.cross(f, [0, 0, 1]); r /= np.linalg.norm(r); u = np.cross(r, f)
        X = V - cam; x, y, z = X @ r, X @ u, X @ f
        W_, H_ = 300, 400; fl = 2.2 * H_ / 2
        sx = W_ / 2 + fl * x / z; sy = H_ / 2 - fl * y / z
        im = Image.new("RGB", (W_, H_), (25, 25, 30)); g = ImageDraw.Draw(im)
        tz = z[T].mean(1); order = np.argsort(-tz)
        light = np.array([-0.5, -0.7, 0.6]); light /= np.linalg.norm(light)
        lam = (0.35 + 0.75 * np.clip(Nn @ light, 0, 1))
        for k in order:
            a, b, c = T[k]
            # back faces off
            if (sx[b] - sx[a]) * (sy[c] - sy[a]) - (sy[b] - sy[a]) * (sx[c] - sx[a]) > 0: continue
            cc = (col[[a, b, c]] * lam[[a, b, c], None]).mean(0).clip(0, 1)
            g.polygon([(sx[a], sy[a]), (sx[b], sy[b]), (sx[c], sy[c])], fill=tuple(int(v * 255) for v in cc))
        ims.append(im)
    sheet = Image.new("RGB", (300 * len(ims), 400)); [sheet.paste(im, (300 * i, 0)) for i, im in enumerate(ims)]
    sheet.save(f"{d}/check/{mid}.png"); print("ok", mid)
