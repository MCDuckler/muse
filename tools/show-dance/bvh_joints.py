# blender -b --python bvh_joints.py -- <in.bvh> <out.npz>
# World joint positions per frame at 30 fps, under the Bandai-Namco names (skel.py),
# scaled so the legs are 0.85 m long whatever the capture's units.
import bpy, sys, os, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import skel, retarget
a = sys.argv[sys.argv.index("--") + 1:]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_anim.bvh(filepath=a[0], axis_forward="-Z", axis_up="Y", global_scale=0.01)
ob = bpy.context.object; sc = bpy.context.scene
f0, f1 = map(int, ob.animation_data.action.frame_range)
fps = skel.bvh_fps(a[0])
step = max(1, round(fps / 30))
M = skel.name_map([b.name for b in ob.pose.bones])
names = retarget.CHAIN
frames = list(range(f0, f1 + 1, step))
P = np.zeros((len(frames), len(names), 3), np.float32)
for i, f in enumerate(frames):
    sc.frame_set(f)
    for j, n in enumerate(names):
        P[i, j] = skel.head(ob.pose.bones, ob.matrix_world, M[n])
iu, il, ifo = names.index("UpperLeg_L"), names.index("LowerLeg_L"), names.index("Foot_L")
leg = np.median(np.linalg.norm(P[:, iu] - P[:, il], axis=1) + np.linalg.norm(P[:, il] - P[:, ifo], axis=1))
P *= 0.85 / leg
P[..., 2] -= np.percentile(np.minimum(P[:, names.index("Toes_L"), 2], P[:, names.index("Toes_R"), 2]), 5)
np.savez(a[1], P=P, names=np.array(names), fps=30.0, f0=f0, step=step)
print("saved", a[1], P.shape, "step", step, "leg", leg, flush=True)
