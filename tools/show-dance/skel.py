# (CMU's Spine1 ends where its Neck starts, so its chest is put between Spine and Spine1.)
# Joint names of the capture skeletons we read, mapped onto the Bandai-Namco names the
# rig and the retarget use (retarget.CHAIN).
CMU = {"Hips": "Hips", "Spine": "Spine", "Chest": ("Spine", "Spine1", 0.4), "Neck": "Neck", "Head": "Head",
       "Shoulder_L": "LeftShoulder", "UpperArm_L": "LeftArm", "LowerArm_L": "LeftForeArm", "Hand_L": "LeftHand",
       "Shoulder_R": "RightShoulder", "UpperArm_R": "RightArm", "LowerArm_R": "RightForeArm", "Hand_R": "RightHand",
       "UpperLeg_L": "LeftUpLeg", "LowerLeg_L": "LeftLeg", "Foot_L": "LeftFoot", "Toes_L": "LeftToeBase",
       "UpperLeg_R": "RightUpLeg", "LowerLeg_R": "RightLeg", "Foot_R": "RightFoot", "Toes_R": "RightToeBase"}


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
        return dict(CMU)
    return {k: k for k in CMU}


def bvh_fps(path):
    for line in open(path):
        if line.strip().startswith("Frame Time"):
            return 1 / float(line.split(":")[1])
    return 30.0
