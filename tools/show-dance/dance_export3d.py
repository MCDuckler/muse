# The dancer for WetOwl's live 3D render: the skinned scan, its skeleton and every move
# sampled on the beat.
#   blender -b rig_long.blend --python dance_export3d.py -- <out dir>
# writes dancer.json (skeleton, moves), dancer.bin (meshes), moves.bin (poses), skin.png.
#
# A move: <beats> capture beats sampled FPB times a beat (and once more at its end),
# each sample the hips' world rotation + position and every other bone's rotation
# against its parent (the pose basis). Facing turned to -Y on average, the drift over
# the loop taken out, and the last half beat blended into what led into the first, so
# it loops without a jump.
import bpy, bmesh, sys, os, json, math, struct
import numpy as np
from mathutils import Matrix, Quaternion, Vector
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import retarget

ARGS = sys.argv[sys.argv.index("--") + 1:]
OUT = os.path.abspath(ARGS[0])
MODEL = "--model" in ARGS  # a model made by dance_model.py: its actions are in the file already
os.makedirs(OUT, exist_ok=True)
HOME = os.path.expanduser("~/scans/chris_v1")
FPB = 8
sc = bpy.context.scene
rig = next(o for o in bpy.data.objects if o.type == "ARMATURE")
scan = bpy.data.objects["scan"]
W = rig.matrix_world.copy()

# --- actions: long (this file), short, the CMU takes
if not MODEL:
    rig.animation_data.action.name = "long"
    with bpy.data.libraries.load(f"{HOME}/dance_bank/rig_short.blend") as (src, dst):
        dst.actions = ["dance"]
    dst.actions[0].name = "short"
    with bpy.data.libraries.load(f"{HOME}/dance2/rigs_cmu.blend") as (src, dst):
        dst.actions = [a for a in src.actions if a not in ("dance",)]
    for a in dst.actions:
        if a.name.endswith(".001"): a.name = a.name[:-4]
else:
    # the model's skin: its material's picture, at 1024
    img = next((n.image for m in scan.data.materials if m and m.use_nodes for n in m.node_tree.nodes if n.type == "TEX_IMAGE" and n.image), None)
    if img is not None:
        img.scale(1024, 1024)
        img.filepath_raw = f"{OUT}/skin.png"; img.file_format = "PNG"; img.save()
    if rig.animation_data is None: rig.animation_data_create()

bones = [b.name for b in rig.data.bones]
bix = {n: i for i, n in enumerate(bones)}

# --- the meshes: hero and a light one for a crowd
def mesh_block(target_tris):
    ob = scan.copy(); ob.data = scan.data.copy(); sc.collection.objects.link(ob)
    for m in list(ob.modifiers): ob.modifiers.remove(m)
    if ob.data.shape_keys: ob.shape_key_clear()  # a VRM's faces, not wanted
    bpy.context.view_layer.objects.active = ob
    ratio = target_tris / max(1, sum(len(p.vertices) - 2 for p in ob.data.polygons))
    if ratio < 1:
        d = ob.modifiers.new("d", "DECIMATE"); d.ratio = ratio
        bpy.ops.object.modifier_apply(modifier="d")
    t = ob.modifiers.new("t", "TRIANGULATE"); bpy.ops.object.modifier_apply(modifier="t")
    me = ob.data; me.calc_loop_triangles()
    uvl = me.uv_layers.active.data
    M = ob.matrix_world
    gname = {g.index: g.name for g in ob.vertex_groups}
    key, verts, tris = {}, [], []
    for tri in me.loop_triangles:
        idx = []
        for li in tri.loops:
            v = me.loops[li].vertex_index; uv = tuple(round(x, 5) for x in uvl[li].uv)
            k = (v, uv)
            if k not in key:
                key[k] = len(verts); verts.append(k)
            idx.append(key[k])
        tris.append(idx)
    # Skinned once per position (unique), drawn per corner (a position split where the
    # skin's islands meet): src maps each drawn vertex to its position.
    uniq = sorted({v for v, _ in verts}); uix = {v: i for i, v in enumerate(uniq)}
    P, N, BI, BW = [], [], [], []
    Mn = M.to_3x3().inverted().transposed()
    for v in uniq:
        mv = me.vertices[v]
        P.append(M @ mv.co); N.append((Mn @ mv.normal).normalized())
        ws = sorted([(g.weight, bix[gname[g.group]]) for g in mv.groups if gname.get(g.group) in bix and g.weight > 0.001], reverse=True)[:4]
        if not ws: ws = [(1.0, bix["Hips"])]
        s_ = sum(w for w, _ in ws); q = [int(round(255 * w / s_)) for w, _ in ws]
        q[0] += 255 - sum(q)
        BI.append([b for _, b in ws] + [0] * (4 - len(ws))); BW.append(q + [0] * (4 - len(q)))
    UV = [(uv[0], 1 - uv[1]) for _, uv in verts]
    SRC = [uix[v] for v, _ in verts]
    bpy.data.objects.remove(ob)
    blob = (np.array(P, "<f4").tobytes() + np.array(N, "<f4").tobytes() + np.array(BI, "u1").tobytes() + np.array(BW, "u1").tobytes()
            + np.array(UV, "<f4").tobytes() + np.array(SRC, "<u2").tobytes() + np.array(tris, "<u2").tobytes())
    print("mesh", target_tris, "->", len(uniq), "positions", len(verts), "corners", len(tris), "tris", flush=True)
    return {"positions": len(uniq), "verts": len(verts), "tris": len(tris)}, blob

meshes, blobs = [], []
for n in (9000, 2200):
    info, blob = mesh_block(n)
    info["offset"] = sum(len(b) for b in blobs); meshes.append(info); blobs.append(blob)
open(f"{OUT}/dancer.bin", "wb").write(b"".join(blobs))

skel = []
for b in rig.data.bones:
    rw = W @ b.matrix_local
    skel.append({"name": b.name, "parent": bix[b.parent.name] if b.parent else -1,
                 "rest": [round(x, 6) for row in rw for x in row]})

# --- moves
B_old = json.load(open(f"{HOME}/dance_bank/beats.json"))
B_new = json.load(open(f"{HOME}/dance2/beats.json"))
offs = json.load(open(f"{HOME}/dance2/rig_offsets.json"))
picks = json.load(open(f"{HOME}/dance2/picks.json"))
cands_new = {(m["clip"], m["beat"], m["beats"]): m for m in json.load(open(f"{HOME}/dance2/candidates.json"))}
moves = []
for m in json.load(open(f"{HOME}/dance_bank/candidates.json")):
    moves.append(dict(id=f'{m["clip"]}{m["beat"]}', action=m["clip"], beats=B_old[m["clip"]]["beats"][m["beat"]:m["beat"] + 9],
                      off=0, style="groove", energy=m["energy"], handsUp=m["hands_up"]))
for style, ms in picks.items():
    for s in ms:
        c, beat, L = s.split(); beat, L = int(beat), int(L)
        m = cands_new[(c, beat, L)]
        moves.append(dict(id=f"{c}_{beat}", action=c, beats=B_new[c]["beats"][beat:beat + L + 1], off=offs[c],
                          style=style, energy=m["energy"], handsUp=m["hands_up"]))

pbs = rig.pose.bones
def sample(t):
    sc.frame_set(int(math.floor(t)), subframe=t - math.floor(t))
    hips = W @ pbs["Hips"].matrix
    q = [hips.to_quaternion()] + [pbs[n].rotation_quaternion.copy() for n in bones[1:]]
    legs = (W @ pbs["UpperLeg_L"].head) - (W @ pbs["UpperLeg_R"].head)
    return q, hips.translation.copy(), legs

def time_at(beats, x):
    """Scene frame at capture beat x (may run before 0) of a move."""
    L = len(beats) - 1
    k = min(max(int(math.floor(x)), 0), L - 1) if x >= 0 else 0
    b0, b1 = beats[k], beats[k + 1]
    return 1 + b0 + (b1 - b0) * (x - k)

frames = []
for mv in moves:
    rig.animation_data.action = bpy.data.actions[mv["action"]]
    L = len(mv["beats"]) - 1; N = L * FPB; H = FPB // 2
    S = [sample(time_at(mv["beats"], j / FPB) - mv["off"]) for j in range(N + 1)]
    pre = [sample(time_at(mv["beats"], (j - H) / FPB) - mv["off"]) for j in range(H)]  # the half beat before
    # facing to -Y: facing = side x up
    ang = [math.atan2(*(lambda f: (f.y, f.x))(s[2].cross(Vector((0, 0, 1))))) for s in S]
    yaw = math.atan2(sum(math.sin(a) for a in ang), sum(math.cos(a) for a in ang))
    Rz = Matrix.Rotation(-math.pi / 2 - yaw, 4, "Z"); qz = Rz.to_quaternion()
    p0 = S[0][1].copy(); p0.z = 0
    drift = S[N][1] - S[0][1]; drift.z = 0
    def fix(s, j):
        q, p, _ = s
        p = Rz.to_3x3() @ (p - p0 - drift * (j / N))
        return [qz @ q[0]] + q[1:], p
    F = [fix(s, j) for j, s in enumerate(S)]
    P_pre = [fix(s, j - H) for j, s in enumerate(pre)]
    mean = sum((f[1] for f in F[:N]), Vector()) / N; mean.z = 0
    F = [(q, p - mean) for q, p in F]; P_pre = [(q, p - mean) for q, p in P_pre]
    # the seam: the last half beat eased into the half beat that led into the start
    for j in range(N - H, N + 1):
        w = (j - (N - H)) / H; w = w * w * (3 - 2 * w)
        src = P_pre[j - (N - H)] if j < N else F[0]
        q = [a.slerp(b if a.dot(b) >= 0 else -b, w) for a, b in zip(F[j][0], src[0])]
        F[j] = (q, F[j][1].lerp(src[1], w))
    blob = bytearray()
    for q, p in F:
        for x in q:
            x = x.normalized()
            if x.w < 0: x = -x
            blob += struct.pack("<4h", *[int(round(c * 32767)) for c in (x.w, x.x, x.y, x.z)])
        blob += struct.pack("<3h", *[int(round(c * 1000)) for c in p])
    mv["offset"] = sum(len(f) for f in frames); frames.append(bytes(blob))
    ivs = np.diff(mv["beats"]) / 30.0
    mv["bpm"] = round(60 / float(np.mean(ivs)), 2)
    print("MOVE", mv["id"], mv["style"], L, "beats", mv["bpm"], "bpm", flush=True)
open(f"{OUT}/moves.bin", "wb").write(b"".join(frames))

en = sorted(m["energy"] for m in moves)
lo, hi = en[int(len(en) * 0.3)], en[int(len(en) * 0.66)]
out = {"dancer": "chris", "fpb": FPB, "bones": skel, "meshes": meshes, "skin": "skin.webp",
       "sample": {"quats": len(bones), "bytes": len(bones) * 8 + 6},
       "moves": [{"id": m["id"], "style": m["style"], "tier": "low" if m["energy"] < lo else ("mid" if m["energy"] < hi else "high"),
                  "energy": round(m["energy"], 2), "bpm": m["bpm"], "beats": len(m["beats"]) - 1, "handsUp": round(m["handsUp"], 2),
                  "offset": m["offset"]} for m in moves]}
json.dump(out, open(f"{OUT}/dancer.json", "w"), separators=(",", ":"))
print("moves", len(moves), "bytes", sum(len(f) for f in frames))
