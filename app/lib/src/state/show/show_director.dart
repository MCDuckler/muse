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
import 'show_rig.dart';
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

  /// What it cannot do without: `cover`, `words`, `camera`, `milk`.
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

  /// The performer's choice: on until the section turns — on a dissolve, or [how].
  void choose(String id, {SceneChange how = SceneChange.dissolve}) {
    if (!scenes.any((s) => s.id == id)) return;
    _heldBy = id;
    _go(id, how, why: 'you chose it');
  }

  /// Scenes turned off by hand, by id: the director never reaches for one and the
  /// arrows step past it. Chosen by name, one still goes on.
  Set<String> off = {};

  /// How much the hands lean on a scene, by id (how often: 0.4 rarely, 2 often);
  /// absent is as any other.
  Map<String, double> leans = const {};

  /// Whether a scene may go on now by the pool's rules (its figure on the ground
  /// that is on): asked of every scene the director weighs; the hands may still
  /// choose one by name.
  bool Function(String id)? allowed;

  // ---------------------------------------------------------------- memory
  /// The family a scene belongs to (`geometric`, `figurative`, `organic`, `media`),
  /// by id: the director turns from one family to another over an evening rather
  /// than from one scene to the next of the same kind.
  Map<String, String> families = const {};

  /// How much each scene has been on, in seconds, fading with a twenty-minute
  /// half-life: what was on a lot lately scores less.
  final Map<String, double> fatigue = {};
  static const fatigueHalfLife = 20 * 60.0;

  /// The director's bias, calm (-1) to busy (+1): the energy a scene is matched
  /// against is moved by a quarter either way.
  double bias = 0;

  /// The ground under the scenes, chosen every so many phrases from [grounds] (the
  /// pool's, weighted; empty is none chosen: the hands' and the macros' way), held
  /// at least [groundHoldBars].
  List<(RigGround, double)> Function()? grounds;
  RigGround? ground;
  int _groundSinceBar = 0;

  /// How many bars the director's background has been on.
  int get groundBars => _groundSinceBar;
  static const groundHoldBars = 32;

  void _tire(ShowState s) {
    final dt = s.dt;
    if (dt <= 0) return;
    final k = math.pow(0.5, dt / fatigueHalfLife).toDouble();
    for (final e in fatigue.entries.toList()) {
      fatigue[e.key] = e.value * k;
    }
    final on = _scene;
    if (on != null) fatigue[on] = (fatigue[on] ?? 0) + dt;
  }

  /// [fatigue] summed by family.
  Map<String, double> get familyFatigue {
    final out = <String, double>{};
    for (final e in fatigue.entries) {
      final f = families[e.key];
      if (f != null) out[f] = (out[f] ?? 0) + e.value;
    }
    return out;
  }

  /// The scenes not turned off, nor ruled out — all of them, if every one is.
  List<SceneMeta> get on {
    final on = [
      for (final s in scenes)
        if (!off.contains(s.id) && (allowed?.call(s.id) ?? true)) s
    ];
    return on.isEmpty ? scenes : on;
  }

  void next({int by = 1}) {
    final on = this.on;
    if (on.isEmpty) return;
    final i = on.indexWhere((s) => s.id == _scene);
    final n = ((i < 0 ? 0 : i + by) % on.length + on.length) % on.length;
    choose(on[n].id);
  }

  /// Why the scene on is on, in words (the SHOW page's SCENE row says it), and how
  /// many bars ago it came.
  String why = '';
  int get barsOn => _sinceBar;

  void _go(String id, SceneChange how, {String why = ''}) {
    if (id == _scene) return;
    this.why = why;
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
    final energy = (m.energy * (0.5 + 0.5 * m.level) + bias * 0.25).clamp(0.0, 1.0);
    final family = _scene == null ? null : families[_scene];
    final section = m.section;
    final hasCover = m.coverUrl != null;
    // Words: a line being sung (timed lyrics), not a voice alone — the words figure
    // would set nothing.
    final hasWords = m.lyric != null;
    final out = <(double, SceneMeta)>[];
    final tired = familyFatigue;
    final camOn = (s['cam.on']) > 0.5 && (s['cam.light']) > 0.08;
    final camMotion = s['cam.motion'];
    for (final sc in on) {
      if (sc.needs.contains('cover') && !hasCover) continue;
      if (sc.needs.contains('words') && !hasWords) continue;
      if (sc.needs.contains('camera') && !camOn) continue;
      if (sc.needs.contains('milk') && s['milk.ok'] < 0.5) continue;
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
        } else {
          // No sections listed: any of them, a little less than one named for it.
          score += 2.5;
        }
      }
      // The record's own lean towards this scene (1 is neutral), and the scene's own.
      final lean = s.genome.genes['scene.${sc.id}'];
      if (lean != null) score += (lean - 1) * 1.0;
      score += sc.priority;
      // How often the hands want it: two points either way.
      final hands = leans[sc.id];
      if (hands != null && hands > 0) score += (math.log(hands) / math.ln2).clamp(-1.4, 1.2) * 1.5;
      // What has been on a lot lately scores less (a minute on costs a point, fading);
      // another family than the one on scores a little more.
      score -= (fatigue[sc.id] ?? 0) / 60;
      // And a family on a lot lately tires as a whole (two minutes of shapes cost
      // every shape a point), so the evening turns from shapes to bodies to flow.
      final fam = families[sc.id];
      if (fam != null) score -= (tired[fam] ?? 0) / 120;
      if (family != null && sc.id != _scene && fam != null && fam != family) score += 0.6;
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
    if (bar) {
      _sinceBar++;
      _groundSinceBar++;
    }
    if (section && m.section != _lastSection) {
      _lastSection = m.section;
      // The hands' choice lasts until the section turns — not the turn it landed on
      // (a launch on the bar a section starts on, the section said a frame later).
      if (_sinceBar > 2) _heldBy = null;
    }
    _tire(s);
    // The ground: another every so many phrases, from the pool's.
    final pool = grounds?.call();
    if (pool == null || pool.isEmpty) {
      ground = null;
    } else if (ground == null || !pool.any((g) => g.$1 == ground) || (phrase && _groundSinceBar >= groundHoldBars && _rng.nextDouble() < 0.5)) {
      final total = pool.fold<double>(0, (a, g) => a + g.$2);
      var x = _rng.nextDouble() * total;
      var pick = pool.last.$1;
      for (final (g, w) in pool) {
        x -= w;
        if (x <= 0) {
          pick = g;
          break;
        }
      }
      if (ground == null || pick != ground) {
        ground = pick;
        _groundSinceBar = 0;
      }
    }

    var fits = fitting(s);
    // Nothing that suits (every scene that would is turned off, or wants what is not
    // here): any that is on, rather than none.
    if (fits.isEmpty) fits = on;
    if (_scene == null) {
      _go(fits.first.id, SceneChange.cut, why: 'the best fit for the start');
    } else if (_heldBy == null && !locked) {
      final current = fits.indexWhere((f) => f.id == _scene);
      final suits = current >= 0 && current < 2;
      if (drop) {
        // A drop: a scene that suits it and is full the moment it is on, cut on it,
        // with a hit. Never a simulation, which would be a black frame on the drop.
        final pick = fits.firstWhere((f) => f.instant, orElse: () => fits.first).id;
        if (pick != _scene) _go(pick, SceneChange.hit, why: 'the drop: the best fit that is full at once');
      } else if (section && !suits) {
        _go(fits.first.id, m.breakdown ? SceneChange.dissolve : SceneChange.cut, why: 'the section turned${m.section != null ? ' to the ${m.section}' : ''}: the best fit');
      } else if (phrase && _sinceBar >= _keepBars && (!suits || _rng.nextDouble() < 0.35)) {
        // On a phrase, after a while: a change for variety among what suits.
        final pool = fits.take(3).where((f) => f.id != _scene).toList();
        // After the dancer, more often than not, the birds: the flock seeds itself
        // from her pose, so she turns into them.
        if ((_scene?.startsWith('dance-') ?? false) && fits.any((f) => f.id == 'flock') && _rng.nextDouble() < 0.6) {
          _go('flock', SceneChange.dissolve, why: 'after the dancers, the birds');
        } else if (pool.isNotEmpty) {
          _go(pool[_rng.nextInt(pool.length)].id, SceneChange.dissolve, why: 'a new phrase: another of the three that fit best');
        }
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
