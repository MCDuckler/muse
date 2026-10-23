import os, re

# (CMU's Spine1 ends where its Neck starts, so its chest is put between Spine and Spine1.)
# Joint names of the capture skeletons we read, mapped onto the Bandai-Namco names the
# rig and the retarget use (retarget.CHAIN).
CMU = {"Hips": "Hips", "Spine": "Spine", "Chest": ("Spine", "Spine1", 0.4), "Neck": "Neck", "Head": "Head",
       "Shoulder_L": "LeftShoulder", "UpperArm_L": "LeftArm", "LowerArm_L": "LeftForeArm", "Hand_L": "LeftHand",
       "Shoulder_R": "RightShoulder", "UpperArm_R": "RightArm", "LowerArm_R": "RightForeArm", "Hand_R": "RightHand",
       "UpperLeg_L": "LeftUpLeg", "LowerLeg_L": "LeftLeg", "Foot_L": "LeftFoot", "Toes_L": "LeftToeBase",
       "UpperLeg_R": "RightUpLeg", "LowerLeg_R": "RightLeg", "Foot_R": "RightFoot", "Toes_R": "RightToeBase"}
# Mixamo's names are CMU's, with a third spine bone the shoulders hang from (its chest).
MIXAMO = dict(CMU, Chest="Spine2")


def head(pose_bones, M, src):
    """World position of a mapped joint: a bone's head, or a point between two."""
    if isinstance(src, tuple):
        a, b, t = src
        return (M @ pose_bones[a].head).lerp(M @ pose_bones[b].head, t)
    return M @ pose_bones[src].head


def name_map(bone_names):
    """Bandai name -> the skeleton's own bone name."""
    names = set(bone_names)
    if "LeftUpLeg" in names and "UpperLeg_L" not in names:
        return dict(MIXAMO if "Spine2" in names else CMU)
    return {k: k for k in CMU}


def capture(bvhdir, take):
    """A take's file: <take>.bvh, or a Mixamo export <take>.fbx."""
    path = f"{bvhdir}/{take}.bvh"
    return path if os.path.exists(path) else f"{bvhdir}/{take}.fbx"


def load(path):
    """A capture imported (BVH, or a Mixamo FBX with its `mixamorig:` prefix taken off the
    bones): the armature, in metres-ish world units, and its frame rate."""
    import bpy
    if path.endswith(".fbx"):
        bpy.ops.import_scene.fbx(filepath=path)
        ob = next(o for o in bpy.context.selected_objects if o.type == "ARMATURE")
        for b in ob.data.bones:
            b.name = re.sub(r"^mixamorig\d*:", "", b.name)
        return ob, bpy.context.scene.render.fps / bpy.context.scene.render.fps_base
    bpy.ops.import_anim.bvh(filepath=path, axis_forward="-Z", axis_up="Y", global_scale=0.01)
    return bpy.context.object, bvh_fps(path)


def bvh_fps(path):
    for line in open(path):
        if line.strip().startswith("Frame Time"):
            return 1 / float(line.split(":")[1])
    return 30.0
