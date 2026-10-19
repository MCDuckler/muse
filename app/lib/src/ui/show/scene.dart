// A scene: one look of the stage, read off a JSON file in assets/show/scenes/.
//
//   {
//     "id": "tunnel", "name": "Tunnel",
//     "energy": [0.5, 1.0],                   what the director reads (SceneMeta)
//     "sections": ["drop", "chorus"],
//     "needs": ["cover"],
//     "layers": [
//       {"sim": "fluid"},                     a simulation's picture (show_sims.dart)
//       {"shader": "tunnel",                  shaders/show/<name>.frag, the common block
//        "samplers": ["cover"],               images after the block, in this order
//        "knobs": {"m1": 1.0},                uM1..uM4
//        "dim": 1.0}                          how much of it, over the layer below
//     ],
//     "particles": ["sparks", "dust"],      see show_particles.dart
//     "text": {"title": true, "lyrics": true, "where": "low" | "big", "jitter": false},
//     "post": {"trails": 0.86, "bloom": 0.7, "fringe": 0.012, "vignette": 0.7,
//              "tone": 1}                     0 = the picture as drawn, no film curve
//   }
import 'dart:convert';

import 'package:flutter/services.dart';

import '../../state/show/show_director.dart';
import '../../state/show/show_rig.dart';

class SceneLayer {
  const SceneLayer({this.shader, this.sim, this.samplers = const [], this.knobs = const {}, this.dim = 1});

  /// A shader drawn over the layer below — or a simulation (show_sims.dart) whose
  /// picture is laid over it. One or the other.
  final String? shader;
  final String? sim;
  final List<String> samplers;
  final Map<String, double> knobs;
  final double dim;

  double knob(int i) => knobs['m$i'] ?? 0;

  factory SceneLayer.fromJson(Map<String, dynamic> j) => SceneLayer(
        shader: j['shader'] == null ? null : '${j['shader']}',
        sim: j['sim'] == null ? null : '${j['sim']}',
        samplers: [for (final s in (j['samplers'] as List? ?? const [])) '$s'],
        knobs: {for (final e in ((j['knobs'] as Map?) ?? const {}).entries) '${e.key}': (e.value as num).toDouble()},
        dim: (j['dim'] as num?)?.toDouble() ?? 1,
      );
}

class SceneText {
  const SceneText({this.title = false, this.lyrics = false, this.where = 'low', this.jitter = false});
  final bool title, lyrics, jitter;
  final String where;
  bool get big => where == 'big';

  factory SceneText.fromJson(Map<String, dynamic>? j) => j == null
      ? const SceneText()
      : SceneText(
          title: j['title'] == true,
          lyrics: j['lyrics'] == true,
          where: '${j['where'] ?? 'low'}',
          jitter: j['jitter'] == true,
        );
}

class ScenePost {
  const ScenePost({this.trails = 0, this.bloom = 0.5, this.fringe = 0.008, this.vignette = 0.6, this.grain = 0.5, this.recipe = 0, this.tone = 1});

  /// The trails are added to the frame, so at 0.5 light lingers for a few frames and
  /// at 0.8 it piles up (the finish's curve keeps it from clipping, but it will be
  /// bright). Past 0.9 is a mistake.
  final double trails, bloom, fringe, vignette, grain;

  /// How much of the record's feedback recipe (its genome) is applied to the
  /// trails, 0..1: the fold, the warp, the turn of the hue, the drift.
  final double recipe;

  /// How much of the finish's film curve (ACES) the scene goes through, 0..1. A
  /// scene of light wants it; one of photographs wants 0, or every white is grey.
  final double tone;

  factory ScenePost.fromJson(Map<String, dynamic>? j) => j == null
      ? const ScenePost()
      : ScenePost(
          trails: ((j['trails'] as num?)?.toDouble() ?? 0).clamp(0.0, 0.92),
          bloom: (j['bloom'] as num?)?.toDouble() ?? 0.5,
          fringe: (j['fringe'] as num?)?.toDouble() ?? 0.008,
          vignette: (j['vignette'] as num?)?.toDouble() ?? 0.6,
          grain: (j['grain'] as num?)?.toDouble() ?? 0.5,
          recipe: ((j['recipe'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0),
          tone: ((j['tone'] as num?)?.toDouble() ?? 1).clamp(0.0, 1.0),
        );
}

class Scene {
  const Scene(
      {required this.id, required this.name, required this.meta, required this.layers, required this.text, required this.post, this.particles = const []});
  final String id, name;
  final SceneMeta meta;
  final List<SceneLayer> layers;
  final SceneText text;
  final ScenePost post;

  /// The particle systems over the layers: `sparks` (a burst on the kick), `dust`
  /// (motes drifting, always), `rise` (streaks climbing with a build), `rain`
  /// (falling with the top end).
  final List<String> particles;

  /// Every shader the scene draws with.
  Iterable<String> get shaders => [
        for (final l in layers)
          if (l.shader != null) l.shader!
      ];

  factory Scene.fromJson(Map<String, dynamic> j) => Scene(
        id: '${j['id']}',
        name: '${j['name'] ?? j['id']}',
        meta: SceneMeta.fromJson(j),
        layers: [for (final l in (j['layers'] as List? ?? const [])) SceneLayer.fromJson((l as Map).cast())],
        text: SceneText.fromJson((j['text'] as Map?)?.cast()),
        post: ScenePost.fromJson((j['post'] as Map?)?.cast()),
        particles: [for (final p in (j['particles'] as List? ?? const [])) '$p'],
      );
}

/// Every scene shipped, by id, in the order of the files.
class SceneBook {
  const SceneBook(this.scenes);
  final Map<String, Scene> scenes;

  Scene? operator [](String? id) => id == null ? null : scenes[id];
  List<SceneMeta> get metas => [for (final s in scenes.values) s.meta];
  Iterable<String> get shaders => {for (final s in scenes.values) ...s.shaders};

  static const dir = 'assets/show/scenes/';

  static Future<SceneBook> load() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final paths = manifest.listAssets().where((p) => p.startsWith(dir) && p.endsWith('.json')).toList()..sort();
    final scenes = <String, Scene>{};
    for (final p in paths) {
      try {
        final j = jsonDecode(await rootBundle.loadString(p));
        if (j is Map<String, dynamic>) {
          final s = Scene.fromJson(j);
          scenes[s.id] = s;
        }
      } catch (e) {
        // One bad file is one scene fewer, not no show.
        // ignore: avoid_print
        print('scene $p: $e');
      }
    }
    return SceneBook(scenes);
  }

  /// From strings, for a test.
  static SceneBook fromStrings(Iterable<String> jsons) => SceneBook({
        for (final s in jsons)
          if (jsonDecode(s) case final Map<String, dynamic> j) Scene.fromJson(j).id: Scene.fromJson(j),
      });
}

/// A scene file read as a look (show_rig.dart): what it draws, as layers. One shader
/// layer is a shader figure (drift a field drawn whole, echo and fold the room), or
/// MilkDrop alone; a simulation is its figure. The post, the
/// text and the particles are the finish. The stages still read the scene; the rig
/// is what travels in the frame and what the panel will edit.
extension SceneLook on Scene {
  Look get look => Look(id: id, name: name, rig: rig, meta: meta, shipped: true);

  ShowRig get rig {
    final finish = RigFinish(
      trails: post.trails,
      bloom: post.bloom,
      tone: post.tone,
      fringe: post.fringe,
      vignette: post.vignette,
      grain: post.grain,
      recipe: post.recipe,
      title: text.title,
      lyrics: text.lyrics,
      where: text.where,
      jitter: text.jitter,
      particles: particles,
    );
    final layer = layers.firstOrNull;
    if (layer == null) return ShowRig(finish: finish);
    final sim = layer.sim;
    if (sim != null) {
      final figure = switch (sim) {
        'fluid' => const RigFigure(kind: Figure.fluid),
        'physarum' => const RigFigure(kind: Figure.veins),
        'siebenschlaefer' => const RigFigure(kind: Figure.meme),
        'turntable' => const RigFigure(kind: Figure.turntable),
        'flock' => const RigFigure(kind: Figure.birds),
        'words' => const RigFigure(kind: Figure.words),
        // The dancers: one scene, its looks the styles (show_dance.dart's DanceArt);
        // the old stages' names read as it, for a recording made before.
        'dance.art' || 'dance.disco' || 'dance.neon' || 'dance.shadow' => const RigFigure(kind: Figure.dancers),
        _ => RigFigure.none,
      };
      return ShowRig(figure: figure, finish: finish);
    }
    final shader = layer.shader;
    if (shader == null) return ShowRig(finish: finish);
    if (layer.samplers.contains('milk')) return ShowRig(ground: RigGround(kind: Ground.milk, knobs: layer.knobs), finish: finish);
    if (layer.samplers.contains('camera')) return ShowRig(figure: RigFigure(kind: Figure.room, knobs: layer.knobs), finish: finish);
    final figure = switch (shader) {
      'kinetic' => Figure.kinetic,
      'blocks' => Figure.blocks,
      'flash' => Figure.flash,
      'glide' => Figure.glide,
      _ => null,
    };
    // Any other shader is drawn whole, blended with the ground like any figure.
    if (figure == null) return ShowRig(figure: RigFigure(kind: Figure.field, knobs: layer.knobs), finish: finish);
    return ShowRig(figure: RigFigure(kind: figure, knobs: layer.knobs), finish: finish);
  }
}

extension SceneBookLooks on SceneBook {
  /// Every scene as a look, by id.
  Map<String, Look> get looks => {for (final s in scenes.values) s.id: s.look};
}
