# blender -b rig_long.blend --python dance_duo.py -- <dance2 dir> <bvh dir> <out.blend>
# The duets (duets.json, chosen from dance_duets.py's sheets): both partners' takes
# retargeted onto the rig over the frames the lead's moves need, an action per take
# named duo_<take>, both of a couple from the same capture frame (the takes run in
# step) -> <out.blend> and duo_offsets.json (each action's first capture frame).
import bpy, sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import retarget, skel
a = sys.argv[sys.argv.index("--") + 1:]
d, bvhdir, out = a
duets = json.load(open(f"{d}/duets.json")); B = json.load(open(f"{d}/beats.json"))
rig = next(o for o in bpy.data.objects if o.type == "ARMATURE")
for act in list(bpy.data.actions): bpy.data.actions.remove(act)
need = {}
for du in duets:
    b = B[du["a"]]["beats"]
    lo, hi = b[du["beat"]], b[du["beat"] + du["beats"]]
    for c in (du["a"], du["b"]):
        l0, h0 = need.get(c, (10 ** 9, 0))
        need[c] = (min(l0, lo), max(h0, hi))
# a couple shares its range, so both actions start on the same capture frame
for du in duets:
    lo = min(need[du["a"]][0], need[du["b"]][0]); hi = max(need[du["a"]][1], need[du["b"]][1])
    need[du["a"]] = need[du["b"]] = (lo, hi)
ranges = {}
for c, (lo, hi) in need.items():
    path = f"{bvhdir}/{c}.bvh"
    fps = skel.bvh_fps(path); step = max(1, round(fps / 30))
    bpy.ops.import_anim.bvh(filepath=path, axis_forward="-Z", axis_up="Y", global_scale=0.01)
    bvh = bpy.context.object
    a0, a1 = map(int, bvh.animation_data.action.frame_range)
    i0 = max(0, lo - 30); i1 = min((a1 - a0) // step, hi + 30)
    n = retarget.retarget(rig, bvh, a0 + i0 * step, a0 + i1 * step, step=step, action_name="duo_" + c)
    rig.animation_data.action.use_fake_user = True
    ranges["duo_" + c] = i0
    act = bvh.animation_data.action
    bpy.data.objects.remove(bvh); bpy.data.actions.remove(act)
    print("DUO", c, n, "frames from", i0, flush=True)
json.dump(ranges, open(f"{d}/duo_offsets.json", "w"))
for o in list(bpy.data.objects):
    if o is not rig: bpy.data.objects.remove(o)
rig.animation_data.action = None
bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(out))
