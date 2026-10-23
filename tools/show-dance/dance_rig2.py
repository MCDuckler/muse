# blender -b rig_long.blend --python dance_rig2.py -- <dance2 dir> <bvh dir> <out.blend>
# Every picked capture retargeted onto the scan's rig, one action per clip (only the
# frames its moves need, from 30 frames before the first to 30 after the last).
import bpy, sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import retarget, skel
a = sys.argv[sys.argv.index("--") + 1:]
d, bvhdir, out = a
picks = json.load(open(f"{d}/picks.json")); B = json.load(open(f"{d}/beats.json"))
rig = next(o for o in bpy.data.objects if o.type == "ARMATURE")
need = {}
for style, ms in picks.items():
    for s in ms:
        c, beat, L = s.split(); beat, L = int(beat), int(L)
        b = B[c]["beats"]
        lo, hi = need.get(c, (10 ** 9, 0))
        need[c] = (min(lo, b[beat]), max(hi, b[beat + L]))
ranges = {}
for c, (lo, hi) in need.items():
    bvh, fps = skel.load(skel.capture(bvhdir, c)); step = max(1, round(fps / 30))
    a0, a1 = map(int, bvh.animation_data.action.frame_range)
    i0 = max(0, lo - 30); i1 = min((a1 - a0) // step, hi + 30)
    n = retarget.retarget(rig, bvh, a0 + i0 * step, a0 + i1 * step, step=step, action_name=c)
    rig.animation_data.action.use_fake_user = True
    ranges[c] = i0
    act = bvh.animation_data.action
    bpy.data.objects.remove(bvh); bpy.data.actions.remove(act)
    print("RIG", c, n, "frames from", i0, flush=True)
json.dump(ranges, open(f"{d}/rig_offsets.json", "w"))
bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(out))
