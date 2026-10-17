# Direction-based retarget: drives an armature whose bones carry the Bandai-Namco joint names
# from the joint world positions of an imported BVH. Independent of the BVH rest pose.
import bpy
from mathutils import Matrix, Vector
import skel

CHAIN = ["Hips", "Spine", "Chest", "Neck", "Head",
         "Shoulder_L", "UpperArm_L", "LowerArm_L", "Hand_L",
         "Shoulder_R", "UpperArm_R", "LowerArm_R", "Hand_R",
         "UpperLeg_L", "LowerLeg_L", "Foot_L", "Toes_L",
         "UpperLeg_R", "LowerLeg_R", "Foot_R", "Toes_R"]
CHILD = {"Hips": "Spine", "Spine": "Chest", "Chest": "Neck", "Neck": "Head",
         "Shoulder_L": "UpperArm_L", "UpperArm_L": "LowerArm_L", "LowerArm_L": "Hand_L",
         "Shoulder_R": "UpperArm_R", "UpperArm_R": "LowerArm_R", "LowerArm_R": "Hand_R",
         "UpperLeg_L": "LowerLeg_L", "LowerLeg_L": "Foot_L", "Foot_L": "Toes_L",
         "UpperLeg_R": "LowerLeg_R", "LowerLeg_R": "Foot_R", "Foot_R": "Toes_R"}


def frames_for(J):
    """J: name -> world Vector of joint heads (+ 'HeadTop', 'HandTip_L/R', 'ToeTip_L/R').
    Returns name -> 3x3 world rotation whose Y = bone direction, X = consistent secondary."""
    up = Vector((0, 0, 1))
    hip_side = (J["UpperLeg_L"] - J["UpperLeg_R"]).normalized()
    sh_side = (J["UpperArm_L"] - J["UpperArm_R"]).normalized()
    spine_dir = (J["Chest"] - J["Hips"]).normalized()
    hips_fwd = spine_dir.cross(hip_side).normalized()      # character forward
    chest_fwd = (J["Neck"] - J["Chest"]).normalized().cross(sh_side).normalized()
    F = {}

    def frame(d, sec):
        d = d.normalized(); x = (sec - d * sec.dot(d))
        if x.length < 1e-6:
            x = up.cross(d) if abs(d.dot(up)) < 0.95 else Vector((1, 0, 0))
        x.normalize(); z = x.cross(d)
        return Matrix((x, d, z)).transposed()

    def hinge(u, l, ref):
        u = u.normalized(); l = l.normalized()
        bent = u.cross(l); base = u.cross(ref)
        w = min(1.0, bent.length / 0.35)                    # trust the bend once it is clear
        if bent.length > 1e-6: bent.normalize()
        if base.length > 1e-6: base.normalize()
        h = bent * w + base * (1 - w)
        return h if h.length > 1e-6 else base

    tip = {"Head": J["HeadTop"], "Hand_L": J["HandTip_L"], "Hand_R": J["HandTip_R"],
           "Toes_L": J["ToeTip_L"], "Toes_R": J["ToeTip_R"]}
    for b in CHAIN:
        end = tip[b] if b in tip else J[CHILD[b]]
        d = end - J[b]
        if b in ("Hips", "Spine"):
            F[b] = frame(d, hip_side.lerp(sh_side, 0.0 if b == "Hips" else 0.5))
        elif b in ("Chest", "Neck", "Head"):
            F[b] = frame(d, sh_side)
        elif b.startswith("Shoulder"):
            F[b] = frame(d, chest_fwd)
        elif b.startswith(("UpperArm", "LowerArm", "Hand")):
            s = b[-1]; u = J["LowerArm_" + s] - J["UpperArm_" + s]; l = J["Hand_" + s] - J["LowerArm_" + s]
            F[b] = frame(d, hinge(u, l, chest_fwd))
        elif b.startswith(("UpperLeg", "LowerLeg")):
            s = b[-1]; u = J["LowerLeg_" + s] - J["UpperLeg_" + s]; l = J["Foot_" + s] - J["LowerLeg_" + s]
            F[b] = frame(d, hinge(u, l, -hips_fwd))
        else:  # feet / toes: keep the side axis horizontal
            F[b] = frame(d, d.cross(up) if abs(d.normalized().dot(up)) < 0.95 else hip_side)
    return F


def bvh_joints(bvh_ob):
    M = bvh_ob.matrix_world; pb = bvh_ob.pose.bones
    names = skel.name_map([b.name for b in pb])
    J = {n: skel.head(pb, M, names[n]) for n in CHAIN}
    J["HeadTop"] = J["Head"] + (J["Head"] - J["Neck"]).normalized() * 0.18
    for s in "LR":
        J["HandTip_" + s] = J["Hand_" + s] + (J["Hand_" + s] - J["LowerArm_" + s]).normalized() * 0.15
        J["ToeTip_" + s] = J["Toes_" + s] + (J["Toes_" + s] - J["Foot_" + s]).normalized() * 0.06
    return J


def rig_rest_joints(arm_ob):
    M = arm_ob.matrix_world; bs = arm_ob.data.bones
    J = {n: M @ bs[n].head_local for n in CHAIN}
    J["HeadTop"] = M @ bs["Head"].tail_local
    for s in "LR":
        J["HandTip_" + s] = M @ bs["Hand_" + s].tail_local
        J["ToeTip_" + s] = M @ bs["Toes_" + s].tail_local
    return J


def retarget(arm_ob, bvh_ob, frame_start, frame_end, step=1, action_name="dance"):
    sc = bpy.context.scene
    rest = frames_for(rig_rest_joints(arm_ob))
    bones = arm_ob.data.bones
    Rinv = arm_ob.matrix_world.to_3x3().inverted()
    arm_ob.animation_data_create()
    arm_ob.animation_data.action = bpy.data.actions.new(action_name)
    for pbn in arm_ob.pose.bones:
        pbn.rotation_mode = "QUATERNION"
    sc.frame_set(frame_start)
    J0 = bvh_joints(bvh_ob)
    hips_rest = arm_ob.matrix_world @ bones["Hips"].head_local
    # The capture's size from its legs (a dance may start crouched), its floor from its toes.
    import statistics
    legs, toes = [], []
    for f in range(frame_start, frame_end + 1, max(1, (frame_end - frame_start) // 200)):
        sc.frame_set(f); J = bvh_joints(bvh_ob)
        legs.append((J["UpperLeg_L"] - J["LowerLeg_L"]).length + (J["LowerLeg_L"] - J["Foot_L"]).length)
        toes += [J["Toes_L"].z, J["Toes_R"].z]
    rleg = (bones["UpperLeg_L"].head_local - bones["LowerLeg_L"].head_local).length + (bones["LowerLeg_L"].head_local - bones["Foot_L"].head_local).length
    scale = rleg * arm_ob.matrix_world.to_scale().x / statistics.median(legs)
    toes.sort(); floor = toes[len(toes) // 20]
    rtoe = (arm_ob.matrix_world @ bones["Toes_L"].head_local).z
    sc.frame_set(frame_start)
    origin = Vector((J0["Hips"].x, J0["Hips"].y, 0))
    out = 1
    for f in range(frame_start, frame_end + 1, step):
        sc.frame_set(f)
        J = bvh_joints(bvh_ob)
        T = frames_for(J)
        world = {}  # armature-space 3x3 pose rotation per bone
        for b in CHAIN:
            D = T[b] @ rest[b].transposed()                 # world delta from rest
            world[b] = Rinv @ D @ arm_ob.matrix_world.to_3x3() @ bones[b].matrix_local.to_3x3()
        for b in CHAIN:
            bone = bones[b]; pbn = arm_ob.pose.bones[b]
            if bone.parent:
                p = bone.parent
                rel_rest = p.matrix_local.to_3x3().inverted() @ bone.matrix_local.to_3x3()
                basis = (world[p.name] @ rel_rest).inverted() @ world[b]
            else:
                basis = bone.matrix_local.to_3x3().inverted() @ world[b]
                hp = (J["Hips"] - origin - Vector((0, 0, floor))) * scale + Vector((0, 0, rtoe))
                hp_arm = arm_ob.matrix_world.inverted() @ hp
                pbn.location = bone.matrix_local.to_3x3().inverted() @ (hp_arm - bone.head_local)
                pbn.keyframe_insert("location", frame=out)
            pbn.rotation_quaternion = basis.to_quaternion()
            pbn.keyframe_insert("rotation_quaternion", frame=out)
        out += 1
    sc.frame_start, sc.frame_end = 1, out - 1
    return out - 1
