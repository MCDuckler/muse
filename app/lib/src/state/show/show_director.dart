// The director: which scene is on, in which combination (show_combos.dart), and
// when they change.
//
// Reads the frame and the moments and decides, by rule: a scene fits a section
// and a band of energy (the scene files say which, see ui/show/scene.dart); a
// change waits for a phrase, or a section turning, or a drop; a drop lands with a
// cut and a hit, a breakdown goes through a dissolve; and the performer's next/prev
// override it until the next section. The combination — background, style, mask,
// blend — is drawn by the rules' weights for the scene on: the background kept a
// while, the rest turned on the sections and the phrases. Deterministic from its
// seed, so a recording plays the same show twice.
//
// How the combinations look is measured (combo_scores.dart): the ugly ones never
// come by themselves, and the one drawn is as intense as where the record is — dark
// and spare in an intro or a breakdown, climbing phrase by phrase through a build,
// the hardest on the drop. A record keeps a look of its own (a few backgrounds and
// styles it leans on), and a section that comes back (the second chorus, the second
// drop) brings back its scene and its combination.
import 'dart:math' as math;

import 'combo_scores.dart';
import 'show_combos.dart';
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

/// How the director got from one scene to the next. A mosh is a cut the stage
/// datamoshes: the scene being left dragged on by the new one's motion
/// (native/stage/src/fx.h); where the stage cannot, a cut.
enum SceneChange { cut, dissolve, hit, mosh }

class ShowDirector {
  ShowDirector({this.scenes = const [], int seed = 1}) : _rng = math.Random(seed);

  /// What there is to choose from: handed in by whoever loaded the scene files.
  List<SceneMeta> scenes;
  final math.Random _rng;

  /// How long a dissolve takes, in bars; a cut takes none. Into a calm section
  /// longer ([dissolveFor]).
  static const dissolveBars = 1.0;
  double _dissolveBars = dissolveBars;

  /// The sections that are quiet: never moshed into, dissolved into slowly.
  static const calmSections = {'intro', 'outro', 'breakdown', 'break'};

  /// The loud ones: a change on a phrase is a cut, and moshed more often.
  static const loudSections = {'drop', 'chorus'};

  /// The section the record is in (a breakdown said as one), as of the last frame.
  String? _now;

  /// How many bars a dissolve into [section] takes.
  static double dissolveFor(String? section) => section == 'outro' ? 3 : (calmSections.contains(section) ? 2 : dissolveBars);

  /// How often a change is datamoshed, by where the record is: a drop most of all
  /// (the build smeared by the drop's motion), the loud sections more than the pool's
  /// share, a build less, the quiet ones never.
  static double moshChance(double share, String? section, {bool drop = false}) {
    if (share <= 0) return 0;
    if (drop) return math.min(0.9, share * 1.6);
    if (calmSections.contains(section)) return 0;
    if (loudSections.contains(section)) return math.min(0.8, share * 1.3);
    if (section == 'build') return share * 0.5;
    return share;
  }

  /// A scene is kept at least this long, in bars, unless a drop or the hands say.
  static const _keepBars = 8;

  String? _scene, _from;
  double _k = 1;

  /// How many of the cuts and dissolves are datamoshes instead, 0..1 (the pool's
  /// say); and how many there have been — the stage moshes when it goes up.
  double moshShare = 0;
  int moshes = 0;
  // Its own dice, so the scenes and combinations chosen are as they were without.
  final _moshRng = math.Random(0x6d6f7368);
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

  /// One combination put on by the hands, as it is, held until let go ([locked]).
  void play(Combo c, {SceneChange how = SceneChange.cut}) {
    if (!scenes.any((s) => s.id == c.scene)) return;
    locked = true;
    if (c.scene != _scene) {
      _go(c.scene, how, why: 'you put it on');
    }
    _setCombo(c);
    why = 'you put it on';
  }

  // ---------------------------------------------------------------- combinations
  /// Each scene's figure, by id (the looks'): what styles it has.
  Map<String, Figure> kinds = const {};

  /// How the combinations look (the audit's table); null: the one the app came with.
  ComboScores? get scores => _scores ?? ComboScores.shipped;
  ComboScores? _scores;
  set scores(ComboScores? v) {
    _scores = v;
    _leans = null;
  }

  /// The rules in force (the pool's, shipped and the hands').
  List<ComboRule> get rules => _rules;
  List<ComboRule> _rules = shippedComboRules;
  set rules(List<ComboRule> v) {
    _rules = v;
    _leans = null;
  }

  /// The backgrounds there are now (the camera with a camera on, the cover with a
  /// record's cover…); all of them where none says.
  Set<String> Function()? grounds;

  Combo? _combo, _fromCombo;

  /// The combination on, and the one being left (during a dissolve).
  Combo? get combo => _combo;
  Combo? get fromCombo => _k < 1 ? _fromCombo : null;
  int _comboSinceBar = 0;

  /// How many bars the background on has been on.
  int get groundBars => _groundSinceBar;
  static const groundHoldBars = 16;

  /// How many bars a style, mask and blend are kept at least.
  static const styleBars = 8;

  /// One background held by the hands: the only one there is, while held.
  String? heldGround;

  Set<String> get _groundsNow {
    final held = heldGround;
    if (held != null) return {held};
    final g = grounds?.call();
    return g == null || g.isEmpty ? comboGrounds.toSet() : g;
  }

  /// The combinations of [scene] with their weights, the backgrounds here now.
  List<(Combo, double)> weighted(String scene) {
    final kind = kinds[scene] ?? Figure.none;
    final here = _groundsNow;
    return [
      for (final c in combosOf(scene, kind, grounds: comboGrounds.where(here.contains))) (c, weigh(c)),
    ];
  }

  /// [c]'s weight: the rules', less as it looks worse (none under ComboScores.floor) —
  /// but a combination the hands named themselves comes as they said, however it
  /// measured.
  double weigh(Combo c) => ComboScores.weigh(c, _rules, scores: scores);

  // ---------------------------------------------------------------- the record
  /// How intense the picture should be now, 0..1, by where the record is (null: no
  /// record to say): set every frame.
  double? target;

  /// What a section asks for, before the bar's energy: spare at the ends and in a
  /// breakdown, the drop the hardest, a build climbing as it goes.
  static double sectionIntensity(String? section, double buildK) => switch (section) {
        'intro' => 0.2,
        'outro' => 0.18,
        'breakdown' => 0.15,
        'break' => 0.22,
        'verse' => 0.4,
        'inst' => 0.5,
        'chorus' => 0.68,
        'drop' => 0.92,
        'build' => 0.3 + 0.55 * buildK,
        _ => 0.3 + 0.5 * buildK,
      };

  /// The intensity [m] asks for: its section's, moved by the bar's energy (and the
  /// hands' bias); the last beats before a drop climb towards it.
  static double intensityFor(ShowDeck m, {double bias = 0}) {
    final energy = (m.energy * (0.5 + 0.5 * m.level) + bias * 0.25).clamp(0.0, 1.0);
    var t = 0.65 * sectionIntensity(m.breakdown ? 'breakdown' : m.section, m.buildK) + 0.35 * energy;
    if (m.section == null && m.buildK <= 0) t = 0.2 + 0.7 * energy;
    return t.clamp(0.0, 1.0);
  }

  /// How hard the picture works with the music now, 0 (a quiet part: still) to 1 (a
  /// drop): [intensityFor] past its middle, eased in. The cameras' (stage_camera.dart)
  /// and MilkDrop's accents (milk_accent.dart).
  static double drive(ShowDeck m) {
    final x = ((intensityFor(m) - 0.45) / 0.45).clamp(0.0, 1.0);
    return x * x * (3 - 2 * x);
  }

  /// How far from the [target] a combination may be and still come often.
  static const intensityWidth = 0.2;

  Object? _record;
  int? _recordSeed;

  /// Each section's scene and combination the first time it came on this record:
  /// brought back when the section comes back.
  final _sceneBook = <String, String>{};
  final _comboBook = <String, Combo>{};

  static int _hash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  /// The record's own look: a third of the backgrounds and two in five of the styles
  /// leaned on, the same every time it plays.
  double affinity(Combo c) {
    final seed = _recordSeed;
    if (seed == null) return 1;
    var k = 1.0;
    if (!c.world && _hash('$seed|g|${c.ground}') % 100 < 35) k *= 2.5;
    if (_hash('$seed|s|${c.scene}.${c.style}') % 100 < 40) k *= 1.8;
    return k;
  }

  /// The hands' taste for a combination (show_taste.dart); none: no lean.
  double Function(Combo c)? taste;

  /// How many bars the combination on has been on.
  int get comboBars => _comboSinceBar;

  /// [c]'s weight now: [weigh], times how near it is to the [target], the record's
  /// own look and the hands' taste.
  double leanNow(Combo c, double w) {
    if (w <= 0) return 0;
    var k = affinity(c) * (taste?.call(c) ?? 1);
    final t = target, i = scores?.intensity(c);
    if (t != null && i != null) {
      final d = i - t;
      k *= math.exp(-d * d / (2 * intensityWidth * intensityWidth));
    }
    return w * k;
  }

  void _newRecord(ShowDeck m) {
    final id = m.trackId ?? m.title;
    if (id == _record) return;
    _record = id;
    _recordSeed = id == null ? null : _hash('$id');
    _sceneBook.clear();
    _comboBook.clear();
  }

  /// Each scene's lean, by id: the mean weight of its combinations that are on (0 —
  /// none on: never). Kept until the rules or the backgrounds change.
  Map<String, double> get leans {
    final here = _groundsNow;
    final key = (here.toList()..sort()).join(',');
    if (_leans != null && _leansKey == key) return _leans!;
    _leansKey = key;
    return _leans = {
      for (final sc in scenes)
        sc.id: () {
          var n = 0, sum = 0.0;
          for (final (_, w) in weighted(sc.id)) {
            if (w <= 0) continue;
            n++;
            sum += w;
          }
          return n == 0 ? 0.0 : sum / n;
        }(),
    };
  }

  Map<String, double>? _leans;
  String? _leansKey;

  void _setCombo(Combo c) {
    if (c.ground != _combo?.ground) _groundSinceBar = 0;
    _combo = c;
    _comboSinceBar = 0;
  }

  /// A combination for the scene on, by weight: keeping the background while it has
  /// been on less than [groundHoldBars] (and [keepGround]), keeping the style too
  /// where [keepStyle].
  void _pickCombo({bool keepGround = true, bool keepStyle = false}) {
    final scene = _scene;
    if (scene == null) return;
    final all = weighted(scene);
    final now = _combo;
    List<(Combo, double)> narrow(bool Function(Combo) f) => [
          for (final o in all)
            if (o.$2 > 0 && f(o.$1)) o
        ];
    var pool = all;
    if (now != null && keepGround && _groundSinceBar < groundHoldBars) {
      final same = narrow((c) => c.ground == now.ground || c.world);
      if (same.isNotEmpty) pool = same;
    }
    if (now != null && keepStyle && now.scene == scene) {
      final same = narrow((c) => c.style == now.style && (c.ground == now.ground || c.world));
      if (same.isNotEmpty) pool = same;
    }
    final pick = pickByWeight([for (final (c, w) in pool) (c, leanNow(c, w))], _rng.nextDouble()) ??
        // Every combination of the scene is off: drawn as it is, on black.
        Combo(ground: 'black', scene: scene, style: stylesOfFigure(kinds[scene] ?? Figure.none).first);
    _setCombo(pick);
  }

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

  int _groundSinceBar = 0;

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

  /// The scenes with a combination on — all of them, if none has.
  List<SceneMeta> get on {
    final l = leans;
    final on = [
      for (final s in scenes)
        if ((l[s.id] ?? 1) > 0) s
    ];
    return on.isEmpty ? scenes : on;
  }

  void next({int by = 1, SceneChange how = SceneChange.dissolve}) {
    final on = this.on;
    if (on.isEmpty) return;
    final i = on.indexWhere((s) => s.id == _scene);
    final n = ((i < 0 ? 0 : i + by) % on.length + on.length) % on.length;
    choose(on[n].id, how: how);
  }

  /// Why the scene on is on, in words (the SHOW page's SCENE row says it), and how
  /// many bars ago it came.
  String why = '';
  int get barsOn => _sinceBar;

  void _go(String id, SceneChange how, {String why = '', bool mayMosh = true}) {
    if (id == _scene) return;
    // A cut or a dissolve (not a drop's hit, nor the first scene) moshed, as often as
    // the pool says; one asked for, always.
    if (how == SceneChange.mosh ||
        (mayMosh && _scene != null && moshShare > 0 && _moshRng.nextDouble() < moshChance(moshShare, _now, drop: how == SceneChange.hit))) {
      how = SceneChange.mosh;
      moshes++;
    }
    _dissolveBars = dissolveFor(_now);
    this.why = why;
    _from = _scene;
    _fromCombo = _combo;
    _scene = id;
    _how = how;
    // A cut and a hit are instant; only a dissolve takes its bar.
    _k = how == SceneChange.dissolve ? 0 : 1;
    _sinceBar = 0;
    _pickCombo();
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
      // How often the hands want it (its combinations' weights): two points either way.
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
      _comboSinceBar++;
    }
    _newRecord(m);
    _now = m.breakdown ? 'breakdown' : m.section;
    target = m.playing || m.bpm != null ? intensityFor(m, bias: bias) : null;
    var turned = false;
    if (section && m.section != _lastSection) {
      _lastSection = m.section;
      turned = true;
      // The hands' choice lasts until the section turns — not the turn it landed on
      // (a launch on the bar a section starts on, the section said a frame later).
      if (_sinceBar > 2) _heldBy = null;
    }
    _tire(s);

    var fits = fitting(s);
    // Nothing that suits (every scene that would is turned off, or wants what is not
    // here): any that is on, rather than none.
    if (fits.isEmpty) fits = on;
    if (_scene == null) {
      _go(fits.first.id, SceneChange.cut, why: 'the best fit for the start');
    } else if (_heldBy == null && !locked) {
      final current = fits.indexWhere((f) => f.id == _scene);
      final suits = current >= 0 && current < 2;
      if (!on.any((f) => f.id == _scene)) {
        // The scene on switched off (none of its combinations in the rotation): off
        // it now, not at the next turn — a stage with nothing playing has none.
        _go(fits.first.id, SceneChange.dissolve, why: 'the one on was switched off: the best fit');
      } else if (drop) {
        // A drop: a scene that suits it and is full the moment it is on, cut on it,
        // with a hit. Never a simulation, which would be a black frame on the drop.
        final pick = fits.firstWhere((f) => f.instant, orElse: () => fits.first).id;
        if (pick != _scene) _go(pick, SceneChange.hit, why: 'the drop: the best fit that is full at once');
      } else if (turned && _booked(m.section, fits) != null) {
        _go(_booked(m.section, fits)!, m.breakdown ? SceneChange.dissolve : SceneChange.cut, why: 'the ${m.section} again: its scene, as the last time');
      } else if (section && !suits) {
        _go(fits.first.id, m.breakdown ? SceneChange.dissolve : SceneChange.cut, why: 'the section turned${m.section != null ? ' to the ${m.section}' : ''}: the best fit');
      } else if (phrase && _sinceBar >= _keepBars && (!suits || _rng.nextDouble() < 0.35)) {
        // On a phrase, after a while: a change for variety among what suits.
        final pool = fits.take(3).where((f) => f.id != _scene).toList();
        // After the dancer, more often than not, the birds: the flock seeds itself
        // from her pose, so she turns into them.
        if ((_scene?.startsWith('dance-') ?? false) && fits.any((f) => f.id == 'flock') && _rng.nextDouble() < 0.6) {
          _go('flock', SceneChange.dissolve, why: 'after the dancers, the birds', mayMosh: false);
        } else if (pool.isNotEmpty) {
          // In a loud section a cut on the phrase; elsewhere a dissolve.
          _go(pool[_rng.nextInt(pool.length)].id, loudSections.contains(_now) ? SceneChange.cut : SceneChange.dissolve,
              why: 'a new phrase: another of the three that fit best');
        }
      }
    }

    // The combination: one for the scene where there is none (or its background went
    // away, or its weight went to nothing); a section that came before, the one it
    // had; on a drop a new one, the hardest that suits; through a build another every
    // phrase, each harder than the last; the background another on a phrase after a
    // while; the style, the mask and the blend on a section turning, or a phrase after
    // [styleBars].
    final c = _combo;
    if (_scene != null && !locked) {
      final label = m.breakdown ? 'breakdown' : m.section;
      final booked = turned && label != null ? _comboBook[label] : null;
      if (c == null || c.scene != _scene) {
        _pickCombo();
      } else if ((!c.world && !_groundsNow.contains(c.ground)) || weigh(c) <= 0) {
        _pickCombo(keepGround: false);
      } else if (booked == c) {
        // The section back, its combination still on: kept.
      } else if (booked != null && booked.scene == _scene && weigh(booked) > 0 && _rng.nextDouble() < 0.75) {
        _setCombo(booked);
        _moshCombo(c);
      } else if (drop && _comboSinceBar > 0) {
        _pickCombo(keepGround: false);
        _moshCombo(c, drop: true);
      } else if (phrase && m.buildK > 0.05 && !m.breakdown && _comboSinceBar >= 4) {
        _pickCombo();
        _moshCombo(c);
      } else if (phrase && _groundSinceBar >= groundHoldBars && _rng.nextDouble() < 0.5) {
        _pickCombo(keepGround: false);
        _moshCombo(c);
      } else if ((turned && _comboSinceBar > 2) || (phrase && _comboSinceBar >= styleBars && _rng.nextDouble() < 0.5)) {
        _pickCombo();
        _moshCombo(c);
      }
      if (turned && label != null && _scene != null) {
        _sceneBook.putIfAbsent(label, () => _scene!);
        final now = _combo;
        if (now != null) _comboBook.putIfAbsent(label, () => now);
      }
    }

    // The change under way: a dissolve over a bar, by the frame's time.
    if (_k < 1) {
      final bpm = m.bpm ?? 120;
      final barSeconds = 240 / bpm;
      _k = (_k + s.dt / (barSeconds * _dissolveBars)).clamp(0.0, 1.0);
      if (_k >= 1) _from = null;
    }
    return (scene: _scene, from: _k < 1 ? _from : null, k: _k);
  }

  /// The scene [section] had the first time it came on this record, where it still
  /// fits (among the four best) and is not on already.
  String? _booked(String? section, List<SceneMeta> fits) {
    final was = section == null ? null : _sceneBook[section];
    if (was == null || was == _scene) return null;
    return fits.take(4).any((f) => f.id == was) ? was : null;
  }

  /// A new combination on the same scene (another style, background, blend), moshed
  /// half as often as a change of scene would be where the record is — on a drop as
  /// often.
  void _moshCombo(Combo was, {bool drop = false}) {
    if (_combo != was && moshShare > 0 && _moshRng.nextDouble() < moshChance(moshShare, _now, drop: drop) * (drop ? 1 : 0.5)) moshes++;
  }

  /// Whether the last change was a hit: the engine flashes on it.
  bool takeHit() {
    final was = _how == SceneChange.hit && _sinceBar == 0 && _k >= 1;
    if (was) _how = SceneChange.cut;
    return was;
  }
}
