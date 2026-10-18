# Any humanoid model (a Mixamo/VRM-style skeleton) made a dancer like the scan:
#   blender -b --python dance_model.py -- <model.glb|.vrm|scan rig .blend> <out.blend>
# Its bones renamed to the Bandai-Namco names the rig uses (skel.MIXAMO), the bones
# outside that chain folded into their nearest kept ancestor (their weights too),
# and every capture the scan's rig dances (long, short, the CMU takes, the duets) retarget onto
# it frame for frame from the scan's own rig, so the move tables (beats, offsets) hold.
import bpy, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import retarget
HOME = os.path.expanduser("~/scans/chris_v1")
a = sys.argv[sys.argv.index("--") + 1:]
src, out = os.path.abspath(a[0]), os.path.abspath(a[1])

MIXAMO = {"Hips": "Hips", "Spine": "Spine", "Spine2": "Chest", "Neck": "Neck", "Head": "Head",
          "LeftShoulder": "Shoulder_L", "LeftArm": "UpperArm_L", "LeftForeArm": "LowerArm_L", "LeftHand": "Hand_L",
          "RightShoulder": "Shoulder_R", "RightArm": "UpperArm_R", "RightForeArm": "LowerArm_R", "RightHand": "Hand_R",
          "LeftUpLeg": "UpperLeg_L", "LeftLeg": "LowerLeg_L", "LeftFoot": "Foot_L", "LeftToeBase": "Toes_L",
          "RightUpLeg": "UpperLeg_R", "RightLeg": "LowerLeg_R", "RightFoot": "Foot_R", "RightToeBase": "Toes_R"}

bpy.ops.wm.read_factory_settings(use_empty=True)
if src.endswith(".blend"):
    # another scan, rigged by rig.py: Bandai names already, its own dance dropped
    with bpy.data.libraries.load(src) as (s, d):
        d.objects = list(s.objects)
    for o in d.objects:
        if o is not None: bpy.context.scene.collection.objects.link(o)
    for act in list(bpy.data.actions): bpy.data.actions.remove(act)
else:
    glb = src if src.endswith(".glb") else src + ".glb"
    if glb != src:
        import shutil; shutil.copy(src, glb)
    bpy.ops.import_scene.gltf(filepath=glb)
arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
meshes = [o for o in bpy.data.objects if o.type == "MESH" and len(o.vertex_groups) > 0]
for o in list(bpy.data.objects):
    if o is not arm and o not in meshes:
        bpy.data.objects.remove(o)
# one mesh
bpy.ops.object.select_all(action="DESELECT")
for o in meshes: o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
if len(meshes) > 1: bpy.ops.object.join()
mesh = bpy.context.view_layer.objects.active
mesh.name = "scan"
mesh.data.uv_layers.active_index = 0

# names
keep = set(retarget.CHAIN)
for b in arm.data.bones:
    n = b.name.split(":")[-1]
    b.name = MIXAMO.get(n, n if n in keep else "x_" + n)
missing = keep - {b.name for b in arm.data.bones}
assert not missing, f"missing bones {missing}"
# weights of the dropped bones to their nearest kept ancestor
def kept(b):
    while b is not None and b.name not in keep: b = b.parent
    return b.name if b else "Hips"
drop = {b.name: kept(b.parent) for b in arm.data.bones if b.name not in keep}
vg = mesh.vertex_groups
for name, to in drop.items():
    g = vg.get(name)
    if g is None: continue
    t = vg.get(to) or vg.new(name=to)
    for v in mesh.data.vertices:
        for e in v.groups:
            if e.group == g.index and e.weight > 0:
                t.add([v.index], e.weight, "ADD")
    vg.remove(g)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="EDIT")
eb = arm.data.edit_bones
for name in drop:
    b = eb[name]
    for c in list(b.children):
        c.use_connect = False
        c.parent = b.parent
for name in drop:
    eb.remove(eb[name])
bpy.ops.object.mode_set(mode="OBJECT")
print("bones", [b.name for b in arm.data.bones], flush=True)

# the scan's rig and every action it dances
with bpy.data.libraries.load(f"{HOME}/dance_bank/rig_long.blend") as (s, d):
    d.objects = ["Rig"]
scan_rig = d.objects[0]; bpy.context.scene.collection.objects.link(scan_rig)
scan_rig.animation_data.action.name = "long"
with bpy.data.libraries.load(f"{HOME}/dance_bank/rig_short.blend") as (s, d):
    d.actions = ["dance"]
d.actions[0].name = "short"
with bpy.data.libraries.load(f"{HOME}/dance2/rigs_cmu.blend") as (s, d):
    d.actions = [x for x in s.actions if x != "dance"]
if os.path.exists(f"{HOME}/dance2/rigs_duo.blend"):
    with bpy.data.libraries.load(f"{HOME}/dance2/rigs_duo.blend") as (s, d):
        d.actions = list(s.actions)
srcs = [x for x in bpy.data.actions if not x.name.startswith("m_")]
for act in srcs:
    scan_rig.animation_data.action = act
    f0, f1 = map(int, act.frame_range)
    n = retarget.retarget(arm, scan_rig, 1, f1, step=1, action_name="m_" + act.name)
    arm.animation_data.action.use_fake_user = True
    print("RETARGET", act.name, n, flush=True)
for act in srcs:
    bpy.data.actions.remove(act)
for act in bpy.data.actions:
    act.name = act.name[2:].split(".")[0]
bpy.data.objects.remove(scan_rig)
for o in list(bpy.data.objects):
    if o not in (arm, mesh): bpy.data.objects.remove(o)
bpy.context.scene.render.fps = 30
bpy.ops.wm.save_as_mainfile(filepath=out)
print("saved", out, flush=True)
