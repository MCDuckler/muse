# The dancer's bank (assets/show/dance/)

How the Dancer scenes' body and moves were made. The scan and its rig come from a separate photogrammetry
pipeline (~/scans/chris_v1/scripts on the machine that made them: COLMAP-CUDA + a visual hull, Blender
auto-rig). These scripts take that rig and make the bank the app draws live in 3D (show_dance_rig.dart,
show_dance_draw.dart). The rig is `rig_long.blend`: the scan skinned to a Bandai-Namco-named armature, with
the Bandai `dance-long` capture on it (`rig_short.blend` carries `dance-short`). Blender 4.5 LTS; Python
with numpy + Pillow.

Captures: the Bandai Namco Research Motiondataset (CC BY-NC 4.0) and the CMU Graphics Lab Motion Capture
Database (free for any use), both as BVH. `skel.py` maps CMU joint names onto the Bandai ones;
`retarget.py` is direction based, so any skeleton's rest pose works. Mixamo dances (the user's own Adobe
login) come in as FBX exported without skin at 30 fps, linked into the capture dir as `mx_<name>.fbx`;
`skel.load` reads either kind (a Mixamo skeleton's chest is its Spine2).

1. `blender -b --python bvh_joints.py -- <take>.bvh <dir>/joints/<take>.npz`: joint tracks at 30 fps, legs
   scaled to 0.85 m.
2. `python dance_beats2.py <dir>`: each take's beats and how rhythmic it is, into beats.json. Accents are
   acceleration onsets, the tempo comes from autocorrelation, and the beats from dynamic programming
   (Ellis 2007).
3. `python dance_moves2.py <dir>`: 8-beat moves (4 for a short take) on the strongest periodic accent, into
   candidates.json.
4. `python dance_sheet.py <dir>`: stick-figure contact sheets of the candidates, to choose from by eye. The
   choices go in picks.json, by style: groove, party, toon, swing, latin, folk, calm.
5. `blender -b rig_long.blend --python dance_rig2.py -- <dir> <bvh dir> <dir>/rigs_cmu.blend`: every picked
   take retargeted onto the rig, an action per take.
5b. Duets (two people captured dancing together: CMU 60/61 are one salsa couple take for take, 18_15/19_15
   and 20_01/21_01 a chicken dance side by side): `python dance_duets.py <dir>` puts each couple's 8-beat
   moves back where the two stood (bvh_joints.py keeps each capture's leg length for that) and draws
   sheets/duet_NN.png; the choices go in duets.json. Then
   `blender -b rig_long.blend --python dance_duo.py -- <dir> <bvh dir> <dir>/rigs_duo.blend` retargets both
   halves of every couple over the same capture frames (actions duo_<take>).
6. `blender -b rig_long.blend --python dance_export3d.py -- <out>`: the bank.
   - dancer.json: the skeleton and the moves.
   - dancer.bin: a 9k-triangle and a 2k-triangle mesh, skinned per position, drawn per corner.
   - moves.bin: each move's poses eight times a beat as int16, with the hips in the world and every other
     bone against its parent. Each move is turned to face −y on average, its drift is taken out, and its
     last half beat is blended into the lead-in so it loops. A duet's two halves (moves `<a>x<b>_<beat>a`
     and `…b`, marked `duo` and `part` in dancer.json) are turned, centred and steadied together, so they
     keep their places round the couple's middle (the lead on the left, facing the camera on average).
     The tiers' energy cut-offs are fixed (the first table's), so adding moves doesn't re-tier the rest.
   - skin.webp: the scan's texture at 1024.
7. `python dance3d_check.py <out> <move ids…>`: the bank drawn the way the app draws it, one pose a beat,
   into check/.

Other dancers (assets/show/dance/<id>/): any humanoid with a Mixamo-style skeleton (a 100Avatars VRM, a
Mixamo export) made the same way, from the scan's rig so every model dances the same move table:

8. `blender -b --python dance_model.py -- <model.vrm|.glb> <out>.blend`: bones renamed to the Bandai ones, the
   rest folded into their nearest kept ancestor (weights too), shape keys dropped, and every action the scan's
   rig dances (long, short, the CMU takes) retargeted onto it frame for frame.
9. `blender -b <out>.blend --python dance_export3d.py -- <dir> --model`: the bank as in 6, its skin the model's
   own texture (skin.png at 1024; make skin.webp of it with Pillow).

A pose is a place in the beat, so the app plays it by the deck's beat phase (show_dance.dart).
