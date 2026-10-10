// The director: which scene is on, and when it changes.
//
// Reads the frame and the moments and decides, by rule: a scene fits a section
// and a band of energy (the scene files say which, see ui/show/scene.dart); a
// change waits for a phrase, or a section turning, or a drop; a drop lands with a
// cut and a hit, a breakdown goes through a dissolve; and the performer's next/prev
// override it until the next section. Deterministic from its seed, so a recording
// plays the same show twice.
import 'dart:math' as math;

import 'show_events.dart';
import 'show_state.dart';

/// What the director needs to know of a scene, read off its file.
class SceneMeta {
  const SceneMeta({
    required this.id,
    this.energy = const (0.0, 1.0),
    this.sections = const [],
    this.needs = const [],
    this.priority = 0,
    this.instant = true,
  });

  /// Added to its score where it fits: the scene the director reaches for first.
  final double priority;

  /// Whether it is full the moment it is on. A simulation is not — it starts empty
  /// and fills over seconds — so a drop never cuts into one; it comes in on a
  /// dissolve, which gives it a bar to fill.
  final bool instant;

  final String id;

  /// The energies it suits, 0..1.
  final (double, double) energy;

  /// The section labels it suits; empty is any.
  final List<String> sections;

  /// What it cannot do without: `cover`, `words`.
  final List<String> needs;

  factory SceneMeta.fromJson(Map<String, dynamic> j) {
    final e = j['energy'];
    return SceneMeta(
      id: '${j['id']}',
      energy: e is List && e.length >= 2 ? ((e[0] as num).toDouble(), (e[1] as num).toDouble()) : (0.0, 1.0),
      sections: [for (final s in (j['sections'] as List? ?? const [])) '$s'],
      needs: [for (final s in (j['needs'] as List? ?? const [])) '$s'],
      priority: (j['priority'] as num?)?.toDouble() ?? 0,
      instant: j['instant'] != false,
    );
  }
}

/// How the director got from one scene to the next.
enum SceneChange { cut, dissolve, hit }

class ShowDirector {
  ShowDirector({this.scenes = const [], int seed = 1}) : _rng = math.Random(seed);

  /// What there is to choose from: handed in by whoever loaded the scene files.
  List<SceneMeta> scenes;
  final math.Random _rng;

  /// How long a dissolve takes, in bars; a cut takes none.
  static const dissolveBars = 1.0;

  /// A scene is kept at least this long, in bars, unless a drop or the hands say.
  static const _keepBars = 8;

  String? _scene, _from;
  double _k = 1;
  SceneChange _how = SceneChange.cut;
  int _sinceBar = 0;
  String? _heldBy;
  String? _lastSection;

  String? get scene => _scene;

  /// Held on one scene for good (a demo of it, a test): the rules stay out of it.
  bool locked = false;

  /// The performer's choice: on until the section turns.
  void choose(String id) {
    if (!scenes.any((s) => s.id == id)) return;
    _heldBy = id;
    _go(id, SceneChange.dissolve);
  }

  void next({int by = 1}) {
    if (scenes.isEmpty) return;
    final i = scenes.indexWhere((s) => s.id == _scene);
    final n = ((i < 0 ? 0 : i + by) % scenes.length + scenes.length) % scenes.length;
    choose(scenes[n].id);
  }

  void _go(String id, SceneChange how) {
    if (id == _scene) return;
    _from = _scene;
    _scene = id;
    _how = how;
    // A cut and a hit are instant; only a dissolve takes its bar.
    _k = how == SceneChange.dissolve ? 0 : 1;
    _sinceBar = 0;
  }

  /// The scenes that suit the frame, best first.
  List<SceneMeta> fitting(ShowState s) {
    final m = s.master;
    final energy = (m.energy * (0.5 + 0.5 * m.level)).clamp(0.0, 1.0);
    final section = m.section;
    final hasCover = m.coverUrl != null;
    final hasWords = m.lyric != null || m.vocal > 0.4;
    final out = <(double, SceneMeta)>[];
    final camOn = (s['cam.on']) > 0.5 && (s['cam.light']) > 0.08;
    final camMotion = s['cam.motion'];
    for (final sc in scenes) {
      if (sc.needs.contains('cover') && !hasCover) continue;
      if (sc.needs.contains('words') && !hasWords) continue;
      if (sc.needs.contains('camera') && !camOn) continue;
      var score = 0.0;
      // A room with people moving in it is a room worth showing.
      if (sc.needs.contains('camera')) score += 2.5 * camMotion - 0.5;
      final (lo, hi) = sc.energy;
      if (energy >= lo && energy <= hi) {
        score += 2;
      } else {
        score -= (energy < lo ? lo - energy : energy - hi) * 4;
      }
      if (section != null) {
        if (sc.sections.contains(section)) {
          score += 3;
        } else if (sc.sections.isNotEmpty) {
          score -= 1;
        }
      }
      // The record's own lean towards this scene (1 is neutral), and the scene's own.
      final lean = s.genome.genes['scene.${sc.id}'];
      if (lean != null) score += (lean - 1) * 1.0;
      score += sc.priority;
      out.add((score, sc));
    }
    out.sort((a, b) => b.$1.compareTo(a.$1));
    return [for (final o in out) o.$2];
  }

  /// One frame: the scene for it, the change under way moved on.
  ({String? scene, String? from, double k}) direct(ShowState s, List<ShowEvent> moments) {
    if (scenes.isEmpty) return (scene: null, from: null, k: 1);
    final m = s.master;
    var phrase = false, section = false, drop = false, bar = false;
    for (final e in moments) {
      if (!e.onMaster) continue;
      switch (e.kind) {
        case ShowEventKind.bar:
          bar = true;
        case ShowEventKind.phrase:
          phrase = true;
        case ShowEventKind.section:
          section = true;
        case ShowEventKind.drop:
          drop = true;
        default:
          break;
      }
    }
    if (bar) _sinceBar++;
    if (section && m.section != _lastSection) {
      _lastSection = m.section;
      _heldBy = null;
    }

    final fits = fitting(s);
    if (_scene == null) {
      _go(fits.first.id, SceneChange.cut);
    } else if (_heldBy == null && !locked) {
      final current = fits.indexWhere((f) => f.id == _scene);
      final suits = current >= 0 && current < 2;
      if (drop) {
        // A drop: a scene that suits it and is full the moment it is on, cut on it,
        // with a hit. Never a simulation, which would be a black frame on the drop.
        final pick = fits.firstWhere((f) => f.instant, orElse: () => fits.first).id;
        if (pick != _scene) _go(pick, SceneChange.hit);
      } else if (section && !suits) {
        _go(fits.first.id, m.breakdown ? SceneChange.dissolve : SceneChange.cut);
      } else if (phrase && _sinceBar >= _keepBars && (!suits || _rng.nextDouble() < 0.35)) {
        // On a phrase, after a while: a change for variety among what suits.
        final pool = fits.take(3).where((f) => f.id != _scene).toList();
        if (pool.isNotEmpty) _go(pool[_rng.nextInt(pool.length)].id, SceneChange.dissolve);
      }
    }

    // The change under way: a dissolve over a bar, by the frame's time.
    if (_k < 1) {
      final bpm = m.bpm ?? 120;
      final barSeconds = 240 / bpm;
      _k = (_k + s.dt / (barSeconds * dissolveBars)).clamp(0.0, 1.0);
      if (_k >= 1) _from = null;
    }
    return (scene: _scene, from: _k < 1 ? _from : null, k: _k);
  }

  /// Whether the last change was a hit: the engine flashes on it.
  bool takeHit() {
    final was = _how == SceneChange.hit && _sinceBar == 0 && _k >= 1;
    if (was) _how = SceneChange.cut;
    return was;
  }
}
