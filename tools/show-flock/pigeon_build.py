# The flock's pigeon: from a scan of a museum study skin (MooreLab's Rock Pigeon,
# Columba livia, CC BY 4.0, a GLB) to the app's bird asset — the body as scanned
# (holes filled, decimated to three levels of detail, the texture carried over), two
# wings modelled here and textured from the scan's own feathers, hinged at the
# shoulders so they can flap.
#
#   venv/bin/python -I pigeon_build.py <scan.glb> <out dir> [<preview dir>]
#
# Out: pigeon.json, pigeon.bin, skin.webp (see read_bird in ui/show/show_flock_bird.dart).
#
# The bird's own frame: x forward (the beak), y right, z up, metres, the body's
# middle at the origin. The scan lies beak at -X, back at +Y, so local = (-X, Z, Y).
import io, json, struct, sys, os
import numpy as np
from PIL import Image, ImageDraw
import trimesh
import fast_simplification as fs

CT = {5120: ('i1', 1), 5121: ('u1', 1), 5122: ('i2', 2), 5123: ('u2', 2), 5125: ('u4', 4), 5126: ('f4', 4)}
NC = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}


def load_glb(path):
    b = open(path, 'rb').read()
    magic, ver, length = struct.unpack_from('<III', b, 0)
    assert magic == 0x46546C67, 'not a glb'
    off = 12; js = None; bin_ = None
    while off < length:
        clen, ctype = struct.unpack_from('<II', b, off); off += 8
        chunk = b[off:off + clen]; off += clen
        if ctype == 0x4E4F534A: js = json.loads(chunk.decode())
        elif ctype == 0x004E4942: bin_ = chunk
    return js, bin_


def accessor(js, bin_, idx):
    a = js['accessors'][idx]; bv = js['bufferViews'][a['bufferView']]
    dt, sz = CT[a['componentType']]; n = NC[a['type']]
    start = bv.get('byteOffset', 0) + a.get('byteOffset', 0)
    stride = bv.get('byteStride', sz * n)
    cnt = a['count']
    if stride == sz * n:
        return np.frombuffer(bin_, dt, cnt * n, start).reshape(cnt, n)
    return np.stack([np.frombuffer(bin_, dt, n, start + i * stride) for i in range(cnt)])


def node_world(js):
    out = []
    def walk(ni, M):
        nd = js['nodes'][ni]
        L = np.eye(4)
        if 'matrix' in nd:
            L = np.array(nd['matrix']).reshape(4, 4).T
        else:
            T = np.eye(4); R = np.eye(4); S = np.eye(4)
            T[:3, 3] = nd.get('translation', [0, 0, 0])
            if 'rotation' in nd:
                x, y, z, w = nd['rotation']
                R[:3, :3] = [[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)], [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)], [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]]
            if 'scale' in nd: S[:3, :3] = np.diag(nd['scale'])
            L = T @ R @ S
        W = M @ L
        if 'mesh' in nd: out.append((nd['mesh'], W))
        for c in nd.get('children', []): walk(c, W)
    for n in js['scenes'][js.get('scene', 0)]['nodes']: walk(n, np.eye(4))
    return out


def read_scan(path):
    js, bin_ = load_glb(path)
    P, UV, T, base = [], [], [], 0
    for mi, W in node_world(js):
        for prim in js['meshes'][mi]['primitives']:
            at = prim['attributes']
            p = accessor(js, bin_, at['POSITION']).astype(np.float64)
            p = (W[:3, :3] @ p.T).T + W[:3, 3]
            uv = accessor(js, bin_, at['TEXCOORD_0']).astype(np.float64)
            t = accessor(js, bin_, prim['indices']).reshape(-1, 3).astype(np.int64)
            P.append(p); UV.append(uv); T.append(t + base); base += len(p)
    P = np.concatenate(P); UV = np.concatenate(UV); T = np.concatenate(T)
    im = js['images'][0]; bv = js['bufferViews'][im['bufferView']]
    tex = Image.open(io.BytesIO(bin_[bv.get('byteOffset', 0): bv.get('byteOffset', 0) + bv['byteLength']])).convert('RGB')
    return P, UV, T, tex


def to_local(P):
    # scan: beak -X, back +Y, width Z  ->  bird: x forward, y right, z up
    L = np.stack([-P[:, 0], P[:, 2], P[:, 1]], 1)
    return L


def weld(P, UV, T, tol=1e-5):
    """Vertices at one place made one (the UV of the first kept): the scan is split at
    its texture seams, and a decimation must not treat the seams as edges."""
    key = np.round(P / tol).astype(np.int64)
    _, first, inv = np.unique(key, axis=0, return_index=True, return_inverse=True)
    inv = inv.reshape(-1)
    return P[first], UV[first], inv[T]


def lod(mesh, uv, target_tris):
    """The mesh decimated (quadric collapses) to about target_tris, every new vertex
    carrying the texture coordinate of one of the vertices it came from."""
    V, F = mesh.vertices, mesh.faces
    if len(F) <= target_tris:
        return V.copy(), F.copy(), uv.copy()
    red = 1 - target_tris / len(F)
    V2, F2, collapses = fs.simplify(V, F, target_reduction=red, agg=7, return_collapses=True)
    V3, F3, mapping = fs.replay_simplification(V, F, collapses)
    uv2 = np.zeros((len(V3), 2))
    # the first original vertex of each new one gives the texture coordinate
    order = np.arange(len(V))[::-1]
    uv2[mapping[order]] = uv[order]
    m = trimesh.Trimesh(V3, F3, process=False)
    m.remove_unreferenced_vertices()
    keep = np.unique(F3.reshape(-1))
    return m.vertices, m.faces, uv2[keep] if len(m.vertices) == len(keep) else uv2[:len(m.vertices)]


def wing(side, hinge, span=0.32, uv_box=(0.46, 0.30, 0.74, 0.58)):
    """One wing as a sheet: spanwise stations from the shoulder out, a leading and a
    trailing edge, the trailing edge notched into primaries toward the tip, a little
    camber and dihedral. Returns positions, normals (up), uv, triangles, and the span
    share of every vertex (0 at the hinge, 1 at the tip)."""
    hx, hy, hz = hinge
    S, C = 10, 3
    stations = np.linspace(0, 1, S + 1)
    pos, nrm, uvs, share = [], [], [], []
    for k, s in enumerate(stations):
        y = hy + side * s * span
        # the chord: broad at the root, pointed at the tip, swept a little back
        lead = hx + 0.05 - 0.005 * s - 0.095 * s ** 3
        trail = hx - 0.07 - 0.035 * np.sin(np.pi * min(1.0, s * 1.1)) + 0.03 * s ** 2
        # primaries: the trailing edge saw-toothed over the outer half
        if s > 0.5:
            trail += 0.014 * (0.5 + 0.5 * np.cos(s * 42.0)) * (s - 0.5) * 2
        z = hz + 0.03 * s ** 2  # dihedral
        for c in range(C):
            t = c / (C - 1)
            x = lead + (trail - lead) * t
            zc = z + 0.006 * np.sin(np.pi * t) * (1 - s)  # camber
            pos.append((x, y, zc)); nrm.append((0.0, 0.0, 1.0))
            uvs.append((uv_box[0] + (uv_box[2] - uv_box[0]) * s, uv_box[1] + (uv_box[3] - uv_box[1]) * t))
            share.append(0.02 + 0.98 * s)
    tris = []
    for k in range(S):
        for c in range(C - 1):
            a = k * C + c; b = a + 1; d = a + C; e = d + 1
            # wound so the normal is +z for the right wing (and mirrored for the left)
            if side > 0:
                tris += [(a, d, b), (b, d, e)]
            else:
                tris += [(a, b, d), (b, e, d)]
    return np.array(pos), np.array(nrm), np.array(uvs), np.array(tris), np.array(share) * side


def normals(V, F):
    m = trimesh.Trimesh(V, F, process=False)
    n = np.asarray(m.vertex_normals)
    n = np.nan_to_num(n); l = np.linalg.norm(n, axis=1, keepdims=True); l[l < 1e-9] = 1
    return n / l


def vertex_colours(uv, tex):
    a = np.asarray(tex)
    h, w = a.shape[0], a.shape[1]
    u = (uv[:, 0] * (w - 1)).clip(0, w - 1).astype(int); v = (uv[:, 1] * (h - 1)).clip(0, h - 1).astype(int)
    return a[v, u]


def render(V, N, F, uv, tex, wingw, hinge, flap, path, size=420):
    """A check: the bird flat shaded and textured, from the side, the front and above,
    its wings at `flap` radians."""
    V = V.copy(); hx, hy, hz = hinge
    for i in range(len(V)):
        w = wingw[i]
        if w == 0: continue
        side = 1 if w > 0 else -1
        a = side * flap * (1 + 0.25 * abs(w))
        y0 = hy * side; z0 = hz
        dy, dz = V[i, 1] - y0, V[i, 2] - z0
        V[i, 1] = y0 + dy * np.cos(a) - dz * np.sin(a); V[i, 2] = z0 + dy * np.sin(a) + dz * np.cos(a)
    col = vertex_colours(uv, tex) / 255.0
    sheet = Image.new('RGB', (size * 3, size), (28, 28, 34))
    views = [(np.array([0, -1, 0.0]), np.array([0, 0, 1.0])), (np.array([1, 0, 0.0]), np.array([0, 0, 1.0])), (np.array([0, 0, 1.0]), np.array([1, 0, 0.0]))]
    for k, (eye, up) in enumerate(views):
        f = -eye; r = np.cross(f, up); r /= np.linalg.norm(r); u = np.cross(r, f)
        x = V @ r; y = V @ u; d = V @ f
        ext = 0.38
        sx = size / 2 + x / ext * size / 2; sy = size / 2 - y / ext * size / 2
        img = Image.new('RGB', (size, size), (28, 28, 34)); dr = ImageDraw.Draw(img)
        order = np.argsort(d[F].mean(1))
        fn = np.cross(V[F[:, 1]] - V[F[:, 0]], V[F[:, 2]] - V[F[:, 0]]); fn /= np.linalg.norm(fn, axis=1, keepdims=True) + 1e-9
        light = np.array([-0.4, -0.6, 0.7]); light /= np.linalg.norm(light)
        sh = 0.4 + 0.6 * np.clip(np.abs(fn @ light), 0, 1)
        for ti in order:
            a, b, c = F[ti]
            cc = (col[[a, b, c]].mean(0) * sh[ti] * 255).astype(int)
            dr.polygon([(sx[a], sy[a]), (sx[b], sy[b]), (sx[c], sy[c])], fill=tuple(int(v) for v in cc))
        sheet.paste(img, (k * size, 0))
    sheet.save(path)


def main():
    src, out = sys.argv[1], sys.argv[2]
    prev = sys.argv[3] if len(sys.argv) > 3 else None
    os.makedirs(out, exist_ok=True)
    P, UV, T, tex = read_scan(src)
    P = to_local(P)
    P -= (P.min(0) + P.max(0)) / 2
    # the body's middle a little back from the length's middle (the tail is long)
    P[:, 0] += 0.02
    P, UV, T = weld(P, UV, T)
    body = trimesh.Trimesh(P, T, process=True)
    body.fill_holes()
    # the biggest piece only: the label's strings and crumbs go
    pieces = body.split(only_watertight=False)
    if len(pieces) > 1:
        pieces.sort(key=lambda m: len(m.faces), reverse=True)
        print('pieces', [len(m.faces) for m in pieces[:6]], '-> keeping the biggest')
    # the UVs must follow trimesh's processing: map by nearest original vertex
    from scipy.spatial import cKDTree
    tree = cKDTree(P)
    def uv_of(V):
        _, idx = tree.query(V)
        return UV[idx]
    big = pieces[0] if len(pieces) > 1 else body
    # faces wound the one way, outward (the app leaves the body's back faces out)
    trimesh.repair.fix_normals(big)
    if big.volume < 0:
        big.invert()
    print('volume', round(float(big.volume), 6))
    print('scan', len(P), 'verts', len(T), 'tris; body', len(big.vertices), 'verts', len(big.faces), 'tris; bounds', big.bounds.round(3).tolist())
    uv_big = uv_of(big.vertices)
    hinge = (0.055, 0.03, 0.012)
    lods = []
    for name, target in [('near', 1400), ('mid', 300), ('far', 56)]:
        V, F, uv = lod(big, uv_big, target)
        uv = uv_of(V)  # safest: by place
        N = normals(V, F)
        wingw = np.zeros(len(V))
        # the wings, both sides, at a detail to match
        span_steps = {'near': 10, 'mid': 6, 'far': 3}[name]
        for side in (1, -1):
            wp, wn, wuv, wt, ws = wing(side, hinge)
            if span_steps < 10:
                # fewer stations: take every nth station's rows
                keep_k = np.linspace(0, 10, span_steps + 1).round().astype(int)
                rows = np.concatenate([np.arange(k * 3, k * 3 + 3) for k in keep_k])
                remap = -np.ones(len(wp), int); remap[rows] = np.arange(len(rows))
                wp, wn, wuv, ws = wp[rows], wn[rows], wuv[rows], ws[rows]
                wt = []
                for k in range(span_steps):
                    for c in range(2):
                        a = k * 3 + c; b = a + 1; d = a + 3; e = d + 1
                        wt += [(a, d, b), (b, d, e)] if side > 0 else [(a, b, d), (b, e, d)]
                wt = np.array(wt)
            base = len(V)
            V = np.vstack([V, wp]); N = np.vstack([N, wn]); uv = np.vstack([uv, wuv]); F = np.vstack([F, wt + base]); wingw = np.concatenate([wingw, ws])
        col = vertex_colours(uv, tex)
        lods.append((name, V.astype(np.float32), N.astype(np.float32), uv.astype(np.float32), F.astype(np.uint16), wingw.astype(np.float32), col.astype(np.uint8)))
        print(f'  lod {name}: {len(V)} verts, {len(F)} tris')
        if prev:
            os.makedirs(prev, exist_ok=True)
            render(V, N, F, uv, tex, wingw, hinge, 0.55, f'{prev}/pigeon-{name}-up.png')
            render(V, N, F, uv, tex, wingw, hinge, -0.35, f'{prev}/pigeon-{name}-down.png')
    # write
    blob = bytearray(); meta = {'frame': 'x forward, y right, z up, metres', 'hinge': list(hinge), 'wingspan': 2 * (hinge[1] + 0.30), 'lods': []}
    for name, V, N, uv, F, wingw, col in lods:
        off = len(blob)
        blob += V.tobytes(); blob += N.tobytes(); blob += uv.tobytes(); blob += wingw.tobytes(); blob += col.tobytes(); blob += F.tobytes()
        meta['lods'].append({'name': name, 'verts': int(len(V)), 'tris': int(len(F)), 'offset': off})
    meta['source'] = {'title': 'Rock Pigeon - Columba livia (MLZ:Bird:65962)', 'author': 'MooreLab, Moore Laboratory of Zoology, Occidental College', 'url': 'https://sketchfab.com/3d-models/rock-pigeon-columba-livia-12fac1c431644b7f9480079636aee332', 'license': 'CC BY 4.0'}
    json.dump(meta, open(f'{out}/pigeon.json', 'w'), indent=1)
    open(f'{out}/pigeon.bin', 'wb').write(bytes(blob))
    tex.resize((512, 512), Image.LANCZOS).save(f'{out}/skin.webp', quality=86, method=6)
    print('wrote', out, len(blob), 'bytes')


if __name__ == '__main__':
    main()
