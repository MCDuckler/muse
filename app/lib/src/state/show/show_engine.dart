// The show's engine: the booth read once a frame into a ShowState, and the edges
// between frames said as events.
//
// Runs while the booth is open (BoothClock starts and stops it), on a ticker of its
// own at the screen's rate. Each tick reads the decks' clocks as the ear hears them
// (the time-stretcher's delay taken off, the performer's offset added), what the
// analysis says of that moment (show_deck.dart), the mixer's settings and the mix
// in progress, eases the palette towards the record's, decays the hit, and hands
// the frame on. Everything downstream — the stage, the lights, a recording — reads
// [state] and [events] and nothing else. The booth's facts come through a
// ShowSource (show_source.dart): this process's booth, or the Desk's over the wire.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../booth/booth.dart';
import 'show_director.dart';
import 'show_dynamics.dart';
import 'show_events.dart';
import 'camera_feed.dart';
import 'milk_feed.dart';
import 'show_faves.dart';
import 'show_feed.dart';
import 'show_genome.dart';
import 'show_taste.dart';
import 'show_palette.dart';
import 'show_plan_legacy.dart';
import 'show_pool.dart';
import 'show_rig.dart';
import 'show_tune.dart';
import 'show_snapshots.dart';
import 'show_source.dart';
import 'show_state.dart';
import 'show_store.dart';

class ShowEngine extends ChangeNotifier implements ShowFeed {
  ShowEngine(Booth booth, {ShowStore? store}) : this.fed(BoothShowSource(booth), store: store);

  /// The show over a booth that is not this process's own (show_source.dart): the
  /// WetOwl Desk's, read off the wire by a stage that directs the show itself.
  ShowEngine.fed(this.source, {ShowStore? store}) : store = store ?? ShowStore.forThisDevice() {
    source.said = _pending.add;
    _state = _blank(DateTime.now());
    _macros = _macros.copyWith(seed: seed);
  }

  /// Where each frame's decks, sound and mix come from.
  final ShowSource source;

  // ------------------------------------------------------------------ the document
  /// Where the show's own document is kept (show_store.dart): the pool, the hands'
  /// looks, the rig to start on.
  final ShowStore store;
  ShowDoc _doc = ShowDoc.none;
  ShowDoc get doc => _doc;

  /// What the director may reach for, and the hands' switches (show_pool.dart).
  ShowPool get pool => _doc.pool;

  /// The looks there are, by id: handed in by whoever loaded the scene files, with
  /// the director's scenes. The frame carries the look on as its rig.
  Map<String, Look> get looks => _looks;
  Map<String, Look> _looks = const {};
  set looks(Map<String, Look> v) {
    _looks = v;
    director.families = {for (final l in v.values) l.id: familyOf(l.rig.figure.kind, l.rig.ground.kind)};
    director.kinds = {for (final l in v.values) l.id: l.rig.figure.kind};
    director.grounds = groundsHere;
    StylePool.sceneOf = {
      for (final l in v.values.toList().reversed)
        if (l.rig.figure.kind != Figure.none) l.rig.figure.kind: l.id,
    };
    _readLegacy();
  }

  /// The scenes' figures, by id (what a scene's styles are).
  Map<String, Figure> get kinds => director.kinds;

  /// The combination rules of before the plan read into it, once the scenes are
  /// known (a style's rule is about every scene that has it): the pool's, and the
  /// snapshots kept here.
  void _readLegacy() {
    if (_looks.isEmpty || !_isReady) return;
    final pool = _doc.pool;
    final raw = pool.legacy;
    final oldSnaps = _doc.snapshots.any((s) => s.legacy != null) || (_doc.snapshot?.legacy != null);
    if (raw == null && !oldSnaps) return;
    var doc = _doc;
    if (raw != null) {
      final r = planFromRules(legacyRules(raw), kinds);
      for (final n in r.notes) {
        debugPrint('show: the rules into the plan: $n');
      }
      doc = doc.copyWith(pool: pool.copyWith(plan: r.plan, clearLegacy: true, before: raw));
    }
    if (oldSnaps) {
      ShowSnapshot read(ShowSnapshot s) => s.legacy == null ? s : s.withSetup(setupFromLegacy(s.legacy!));
      doc = doc.copyWith(snapshots: [for (final s in doc.snapshots) read(s)], snapshot: doc.snapshot == null ? null : read(doc.snapshot!));
    }
    setDoc(doc);
  }

  /// A set as the combination rules of before said it (a snapshot of then).
  ShowSetup setupFromLegacy(List<dynamic> raw) => ShowSetup(plan: planFromRules(legacyRules(raw), kinds).plan);

  /// The family a look belongs to, for the director's turns: geometric shapes,
  /// figures in a space, organic simulations, media.
  static String familyOf(Figure f, Ground g) => switch (f) {
        Figure.kinetic || Figure.blocks || Figure.flash || Figure.glide => 'geometric',
        Figure.dancers || Figure.birds || Figure.turntable => 'figurative',
        Figure.fluid || Figure.veins || Figure.field => 'organic',
        Figure.meme || Figure.words || Figure.room || Figure.type3d => 'media',
        Figure.none => 'organic',
      };

  /// The backgrounds there are now: the camera only with a camera on and light in
  /// the room, the cover only with a record's cover; the rest always.
  Set<String> groundsHere() => {
        for (final g in comboGrounds)
          if ((g != 'camera' || (_state['cam.on'] > 0.5)) && (g != 'cover' || _state.master.coverUrl != null)) g
      };

  Future<void>? _ready;
  bool _isReady = false;

  /// The document read, once; where there is none yet, the preferences the show
  /// kept before it had one are taken in and the document written. (Done is kept
  /// as a fact, not as the future that did it: a future made in one zone never
  /// delivers to another — a test's fake clock, mostly.)
  Future<void> ready() {
    if (_isReady) return Future.value();
    return _ready ??= () async {
      var doc = await store.load();
      if (doc == null) {
        doc = await migratedShowDoc();
        await store.save(doc);
      }
      _apply(doc);
      _isReady = true;
      _readLegacy();
    }();
  }

  void _apply(ShowDoc doc) {
    _doc = doc;
    director.plan = doc.pool.plan;
    director.taste = (c) => ShowTaste.lean(c, doc.taste, doc.faves);
    director.bias = doc.pool.bias;
    director.moshShare = doc.pool.mosh;
    MovePool.from(doc.pool);
    StylePool.from(doc.pool);
    QualityPool.from(doc.pool);
    director.grounds = groundsHere;
    // The dancers still read who dances off the hands' macros.
    _macros = _macros.copyWith(dancer: doc.pool.dancer ?? 'mix', dancersOff: doc.pool.dancersOff, tune: doc.pool.tune, type3d: _faveOn?.type3d ?? doc.pool.type3d, adapt: doc.pool.adapt);
    if (!running) tick(DateTime.now());
    notifyListeners();
  }

  Timer? _saving;

  /// The selector's snapshots: this device's and the shared ones (show_snapshots.dart).
  late final SnapshotShelf snapshots = SnapshotShelf(_SnapshotHost(this));

  /// The hands changed the pool: applied now, kept a moment later.
  void setPool(ShowPool p) => setDoc(_doc.copyWith(pool: p));

  /// The hands changed the plan.
  void setPlan(ShowPlan p) => setPool(pool.copyWith(plan: p));

  void setDoc(ShowDoc d) {
    _apply(d);
    _saving?.cancel();
    _saving = Timer(const Duration(milliseconds: 300), () {
      _saving = null;
      unawaited(store.save(_doc));
    });
  }

  // ------------------------------------------------------------------ the hands
  /// A combination put on as it is, held until let go ([holdScene] false, NEXT):
  /// landing on the master's next beat, bar or phrase (the pool's LAND ON, or [at]) —
  /// or now, and now when nothing plays. MilkDrop alone so put on: NEXT steps its
  /// presets.
  void play(Combo c, {Quantise? at}) {
    if (_waits(at)) {
      _launch = (look: c.scene, combo: c, fave: null, at: at ?? pool.quantise, asked: DateTime.now());
      notifyListeners();
      return;
    }
    _letFave();
    _play(c);
  }

  /// Whether a change asked for now waits for its moment.
  bool _waits(Quantise? at) => (at ?? pool.quantise) != Quantise.now && _state.master.playing;

  void _play(Combo c) {
    _launch = null;
    director.play(c);
    _milkOnly = c.scene == 'milk';
    if (_milkOnly) unawaited(MilkFeed.shared.start());
    if (!running) tick(DateTime.now());
    notifyListeners();
  }

  // ------------------------------------------------------------------ favourites
  /// The favourites, newest first (show_faves.dart).
  List<ShowFave> get faves => _doc.faves;

  /// What is on the stage now, as a favourite (its picture is the caller's): null
  /// while nothing is.
  ShowFave? faveNow({DateTime? at}) {
    final c = combo;
    if (c == null) return null;
    final when = at ?? DateTime.now();
    final kind = director.kinds[c.scene] ?? Figure.none;
    final usesMilk = c.ground == 'milk' || c.scene == 'milk';
    final shot = hasCamera(kind) ? StylePool.shotNow[kind] : null;
    final typeNow = StylePool.typeNow;
    return ShowFave(
      id: ShowFave.newId(when),
      at: when,
      combo: c,
      milk: usesMilk ? MilkFeed.shared.preset?.fullName ?? _macros.milkPreset : null,
      shot: shot == null ? null : '${kind.name}.$shot',
      type3d: kind == Figure.type3d && typeNow != null ? narrowedType(_macros.type3d, typeNow) : null,
    );
  }

  /// [f] kept, first in the list (one of the same id replaced).
  void keepFave(ShowFave f) => setDoc(_doc.copyWith(faves: [f, for (final o in faves) if (o.id != f.id) o]));

  /// [f] as it is now (its stars, its name), where it is.
  void putFave(ShowFave f) => setDoc(_doc.copyWith(faves: [for (final o in faves) o.id == f.id ? f : o]));

  void forgetFave(String id) => setDoc(_doc.copyWith(faves: [for (final o in faves) if (o.id != id) o]));

  /// The favourite on the stage, put on by the hands: held until let go (HOLD, NEXT,
  /// another combination or scene).
  ShowFave? get faveOn => _faveOn;
  ShowFave? _faveOn;
  bool _faveMilkDone = false;

  /// [f] on the stage as it was kept, whatever the rules say of it: the combination
  /// held, its MilkDrop preset loaded and held, its framing cut to, its 3D text's
  /// motion, look and bends.
  void playFave(ShowFave f, {Quantise? at}) {
    if (_waits(at)) {
      _launch = (look: f.combo.scene, combo: f.combo, fave: f, at: at ?? pool.quantise, asked: DateTime.now());
      notifyListeners();
      return;
    }
    _faveOn = f;
    _faveMilkDone = f.milk == null;
    StylePool.heldShot = f.shot;
    _macros = _macros.copyWith(type3d: f.type3d ?? pool.type3d);
    if (f.milk != null) unawaited(MilkFeed.shared.start());
    _play(f.combo);
  }

  /// The favourite let go of: the rules' framing, the pool's 3D text, MilkDrop's
  /// director back on its presets.
  void _letFave() {
    final f = _faveOn;
    if (f == null) return;
    _faveOn = null;
    StylePool.heldShot = null;
    if (f.type3d != null) _macros = _macros.copyWith(type3d: pool.type3d);
    if (f.milk != null) MilkFeed.shared.director.release();
  }

  /// The favourite's preset, once MilkDrop is up and its presets are listed (it may
  /// be starting as the favourite goes on).
  void _faveMilk(MilkFeed milk) {
    final want = _faveOn?.milk;
    if (want == null || _faveMilkDone) return;
    if (milk.preset?.fullName == want) {
      _faveMilkDone = true;
      return;
    }
    if (milk.library.presets.isEmpty) return;
    _faveMilkDone = true;
    final p = milk.library.byName(want);
    if (p != null) milk.director.pick(p);
  }

  /// The combination on (the director's, or the hands').
  Combo? get combo => director.combo;

  /// The hands' finish over every scene (the trails, the bloom…); null: each look's
  /// own. And how strong the blend is (1: all of it). Kept (in a set, too).
  RigFinish? get finish => pool.finish;
  void setFinish(RigFinish? f) => setPool(pool.copyWith(finish: f, clearFinish: f == null));

  double get blendStrength => pool.strength;
  void setBlendStrength(double v) => setPool(pool.copyWith(strength: v.clamp(0.0, 1.0)));

  ShowRig _hands(ShowRig r) {
    // The transformation: the hands' held, or the director's for this combination.
    var out = r.copyWith(transform: _transformNow);
    final finish = pool.finish, strength = pool.strength;
    if (finish != null) out = out.copyWith(finish: finish);
    if (strength != 1) out = out.copyWith(blend: out.blend.copyWith(strength: strength));
    return out;
  }

  /// One background held by the hands (MilkDrop under everything, say): the director
  /// keeps to it; null lets it choose again. Not kept.
  String? get heldGround => director.heldGround;
  void holdGround(String? key) {
    director.heldGround = key;
    if (!running) tick(DateTime.now());
    notifyListeners();
  }

  /// The effects' settings (TransformSet: the mirrors, the datamosh's grain…), kept.
  void setTransform(TransformSet t) => setPool(pool.copyWith(transform: t));

  /// An effect held by the hands over whatever comes (the kaleidoscope, the slit-scan,
  /// the datamosh), till let go; null: each combination's own (the plan's effect row).
  /// Not kept.
  Fx? get heldFx => _heldFx;
  Fx? _heldFx;
  void holdFx(Fx? f) {
    _heldFx = f;
    if (!running) tick(DateTime.now());
    notifyListeners();
  }

  /// The effect on: the one the hands hold, or the combination's.
  Fx get fxOn => _heldFx ?? director.combo?.fx ?? Fx.none;

  RigTransform get _transformNow => pool.transform.of(fxOn);

  /// Whether the stages trade the picture's size for their frames, kept.
  void setAdapt(bool on) => setPool(pool.copyWith(adapt: on));

  /// A treatment's knob, kept (null: back to its rest).
  void setTune(String treatment, TuneKnob k, double? v) => setPool(pool.withTune(tuneKey(treatment, k), v));

  /// A move asked for by hand: the lead dances it at the next slot.
  void audition(String moveId) {
    MovePool.audition = moveId;
    notifyListeners();
  }

  // ------------------------------------------------------------------ launches
  /// What the hands asked for, landing on the next beat, bar or phrase of the master
  /// (the pool's LAND ON, or [at]) — or now, and now when nothing plays: a scene, a
  /// combination ([play]) or a favourite ([playFave]).
  ({String look, Combo? combo, ShowFave? fave, Quantise at, DateTime asked})? _launch;
  String? get pendingLook => _launch?.look;
  Combo? get pendingCombo => _launch?.combo;
  ShowFave? get pendingFave => _launch?.fave;
  Quantise? get pendingAt => _launch?.at;

  void launch(String id, {Quantise? at}) {
    if (!looks.containsKey(id) && !director.scenes.any((s) => s.id == id)) return;
    final q = at ?? pool.quantise;
    _letFave();
    if (q == Quantise.now || !_state.master.playing) {
      director.choose(id, how: SceneChange.cut);
      _launch = null;
    } else {
      _launch = (look: id, combo: null, fave: null, at: q, asked: DateTime.now());
    }
    if (!running) tick(DateTime.now());
    notifyListeners();
  }

  void cancelLaunch() {
    _launch = null;
    notifyListeners();
  }

  /// How long a launch waits for its moment before it lands anyway (a record with
  /// no grid, a deck stopped meanwhile).
  static const launchPatience = Duration(seconds: 20);

  void _land(List<ShowEvent> said, DateTime now) {
    final l = _launch;
    if (l == null) return;
    final due = said.any((e) =>
        e.onMaster &&
        switch (l.at) {
          Quantise.beat => e.kind == ShowEventKind.beat || e.kind == ShowEventKind.bar || e.kind == ShowEventKind.phrase,
          Quantise.bar => e.kind == ShowEventKind.bar || e.kind == ShowEventKind.phrase,
          Quantise.phrase => e.kind == ShowEventKind.phrase,
          Quantise.now => true,
        });
    if (!due && now.difference(l.asked) < launchPatience) return;
    _launch = null;
    if (l.fave != null) {
      playFave(l.fave!, at: Quantise.now);
    } else if (l.combo != null) {
      play(l.combo!, at: Quantise.now);
    } else {
      director.choose(l.look, how: SceneChange.cut);
    }
  }

  // ------------------------------------------------------------------ holds
  /// What the hands hold now, each let go of on its own ([letGo]) or all at once.
  List<ShowHold> get holds {
    final milk = MilkFeed.shared.director;
    return [
      if (director.locked) ShowHold.look,
      if (heldGround != null) ShowHold.ground,
      if (_heldFx != null) ShowHold.effect,
      if (MilkFeed.shared.available && (milk.locked || milk.heldByHand)) ShowHold.preset,
      if (_launch != null) ShowHold.pending,
    ];
  }

  void letGo(ShowHold h) {
    switch (h) {
      case ShowHold.look:
        holdScene(false);
      case ShowHold.ground:
        holdGround(null);
      case ShowHold.effect:
        holdFx(null);
      case ShowHold.preset:
        final d = MilkFeed.shared.director;
        if (d.locked) d.set(locked: false);
        d.release();
        notifyListeners();
      case ShowHold.pending:
        cancelLaunch();
    }
  }

  void letGoAll() {
    for (final h in holds) {
      letGo(h);
    }
  }

  /// The performer's offset, in milliseconds: how much later than the deck's clock
  /// the picture should run, to land on the ear. Positive draws later. Measured once
  /// per screen by the tap test; nought until then.
  int offsetMs = 0;

  /// How long a palette takes to ease to the next record's, and a hit to fade.
  static const paletteEase = Duration(seconds: 2);
  static const hitFade = Duration(milliseconds: 350);

  late ShowState _state;
  @override
  ShowState get state => _state;

  final _events = StreamController<ShowEvent>.broadcast(sync: true);
  @override
  Stream<ShowEvent> get events => _events.stream;

  Ticker? _ticker;
  DateTime? _last;
  bool get running => _ticker?.isActive ?? false;

  ShowMacros _macros = ShowMacros.none;
  ShowMacros get macros => _macros;

  /// This session's own number (ShowMacros.seed): the director's turns, the styles,
  /// the treatments and the blends go by it with the record.
  final int seed = seedForTests ?? math.Random().nextInt(0x3fffffff) + 1;

  /// A fixed [seed] for the engines made from here on (the tests').
  @visibleForTesting
  static int? seedForTests;

  /// Which scene is on: see show_director.dart. Its scenes are handed in by whoever
  /// loaded the scene files (the stage, the room's clock).
  late final director = ShowDirector(seed: seed);

  /// The hits and the exposure: see show_dynamics.dart.
  final dynamics = ShowDynamics();
  ShowPalette _palette = ShowPalette.house;
  String _masterName = 'A';
  Genome _genome = Genome.none;
  int? _genomeTrack;

  /// Said by the booth between frames, told on the next.
  final _pending = <ShowEvent>[];

  void start() {
    if (_ticker != null) return;
    // The pool and the rules in force from the first frame, whoever starts the show.
    unawaited(ready());
    _ticker = Ticker(_onTick)..start();
  }

  void stop() {
    _ticker?.dispose();
    _ticker = null;
    _last = null;
  }

  void _onTick(Duration _) => tick(DateTime.now());

  // ------------------------------------------------------------------ the hands
  void setMacros(ShowMacros m) {
    _macros = m;
    if (!running) tick(DateTime.now());
  }

  /// The performer hit the show: a flash that fades over [hitFade]. [at] for a test
  /// driving the clock by hand.
  void hit({DateTime? at}) {
    final now = at ?? DateTime.now();
    _hitAt = now;
    _pending.add(ShowEvent(ShowEventKind.hit, now));
    if (!running) tick(now);
  }

  DateTime? _hitAt;

  /// The performer's hands on the scenes (a launch still waiting is forgotten: the
  /// newer choice stands). With MilkDrop alone on the stage the arrows step its presets.
  void nextScene() {
    if (milkOnly) return MilkFeed.shared.director.next();
    _launch = null;
    _skipped();
    _letFave();
    director.next();
  }

  /// Another scene now, datamoshed into (the hands' MOSH).
  void moshNext() {
    if (milkOnly) return MilkFeed.shared.director.next();
    _launch = null;
    _skipped();
    _letFave();
    director.next(how: SceneChange.mosh);
  }

  /// NEXT in a combination's first bars, the director's own choice (not the hands' or
  /// a favourite): kept as "not this" (show_taste.dart).
  void _skipped() {
    final c = director.combo;
    if (c == null || director.locked || faveOn != null || director.comboBars >= ShowTaste.skipBars) return;
    setDoc(_doc.copyWith(taste: ShowTaste.skipped(_doc.taste, c)));
  }

  void previousScene() {
    if (milkOnly) return MilkFeed.shared.director.previous();
    _launch = null;
    _letFave();
    director.next(by: -1);
  }

  /// The next scene the director may use, whatever is held (a scene just switched
  /// off steps on to one that is on).
  void stepOn() {
    _launch = null;
    _letFave();
    director.next();
    if (!running) tick(DateTime.now());
    notifyListeners();
  }

  /// MilkDrop alone on the stage: the MilkDrop look, held; the arrows and the pads on
  /// its presets instead. Its own flag: HOLD on another scene is not this.
  bool _milkOnly = false;
  bool get milkOnly => _milkOnly && director.scene == 'milk';
  void setMilkOnly(bool on) {
    _launch = null;
    _letFave();
    if (on) {
      if (!director.scenes.any((s) => s.id == 'milk')) return;
      director
        ..choose('milk')
        ..locked = true;
      _milkOnly = true;
      unawaited(MilkFeed.shared.start());
    } else {
      _milkOnly = false;
      director.locked = false;
    }
    if (!running) tick(DateTime.now());
    notifyListeners();
  }

  void chooseScene(String id) {
    _launch = null;
    _letFave();
    director.choose(id);
  }

  /// The scene on held: the director's rules stay off it until it is let go (the
  /// arrows still move it, and the next one is held instead). One look as a mode.
  bool get sceneHeld => director.locked;
  void holdScene(bool on) {
    _launch = null;
    if (!on) _letFave();
    director.locked = on;
    if (!on) _milkOnly = false;
    if (!running) tick(DateTime.now());
    notifyListeners();
  }

  // ------------------------------------------------------------------ the frame
  /// One frame, at [now]. Public for a test; the ticker calls it.
  void tick(DateTime now) {
    final last = _last;
    final dt = last == null ? 0.0 : now.difference(last).inMicroseconds / 1e6;
    _last = now;
    final prev = _state;

    final (:a, :b, :audio, :live, :mix) = source.facts(now, offsetMs);

    // Which deck has the room: the louder channel, and it keeps it until the other
    // is clearly louder — a fader at the middle must not flip the show every frame.
    final cur = _masterName == 'B' ? b : a, oth = _masterName == 'B' ? a : b;
    final curLoud = cur.playing ? cur.level : 0.0, othLoud = oth.playing ? oth.level : 0.0;
    if (othLoud > curLoud + 0.2 || (curLoud == 0 && othLoud > 0)) _masterName = oth.name;
    final master = _masterName == 'B' ? b : a;

    // The record's genome, drawn once per record on the master deck.
    if (master.trackId != _genomeTrack) {
      _genomeTrack = master.trackId;
      _genome = master.trackId == null ? Genome.none : Genome.of(trackId: master.trackId!, camelot: master.camelot, bpm: master.bpm, cover: master.coverColor);
    }

    // The palette eased towards the record's.
    final want = paletteFor(
      coverColor: master.coverColor,
      keyHue: master.keyHue,
      section: master.section,
      colourTurn: _macros.colour + _genome['palette.turn'],
      apart: _genome.isEmpty ? null : _genome['palette.apart'],
    );
    final ease = dt <= 0 ? 1.0 : (dt / (paletteEase.inMicroseconds / 1e6)).clamp(0.0, 1.0);
    _palette = _palette.lerp(want, ease);

    // The hit, fading from when it landed.
    final hitAt = _hitAt;
    final hit = hitAt == null ? 0.0 : (1 - now.difference(hitAt).inMicroseconds / hitFade.inMicroseconds).clamp(0.0, 1.0);
    if (hit != _macros.hit) _macros = _macros.copyWith(hit: hit);
    // The beat before the drop, black (the pool's say): in the frame, not the hands.
    final away = master.dropBeatsAway;
    final dark = pool.darkBeat && master.playing && away != null && away > 0 && away <= 1;
    final frameMacros = dark && !_macros.blackout ? _macros.copyWith(blackout: true) : _macros;

    _state = ShowState(
      now: now,
      dt: dt,
      a: a,
      b: b,
      masterName: _masterName,
      audio: audio,
      mix: mix,
      palette: _palette,
      macros: frameMacros,
      genome: _genome,
    );
    _state = _state.copyWith(dyn: {
      ...dynamics.frame(_state, dt, heard: live.isNotEmpty),
      ...live,
      ...CameraFeed.shared.numbers,
      ...MilkFeed.shared.numbers,
    });

    final said = eventsBetween(prev, _state);
    if (_pending.isNotEmpty) {
      said.addAll(_pending);
      _pending.clear();
    }
    // A launch landing on its moment; then the director's word on the scene, and
    // its hit where it cut on a drop.
    _land(said, now);
    final d = director.direct(_state, said);
    if (director.takeHit()) {
      _hitAt = now;
      _macros = _macros.copyWith(hit: 1);
      said.add(ShowEvent(ShowEventKind.hit, now, data: const {'by': 'director'}));
    }
    // The look on, as layers, with the hands over it; and the one being left.
    final look = looks[d.scene], leaving = looks[d.from];
    // The figures' cameras weigh their next framing by the combination on.
    StylePool.combo = director.combo;
    _state = _state.copyWith(
      scene: d.scene,
      sceneFrom: d.from,
      sceneK: d.k,
      mosh: director.moshes + MilkFeed.shared.director.moshes,
      clearSceneFrom: d.from == null,
      rig: look == null ? ShowRig.none : _hands(look.inCombo(director.combo)),
      rigFrom: leaving == null ? null : _hands(leaving.inCombo(director.fromCombo)),
      macros: dark && !_macros.blackout ? _macros.copyWith(blackout: true) : _macros,
    );
    // MilkDrop, where it is on: the numbers and the sound, and its director's cuts;
    // the preset on goes over the wire, so a stage in another process shows the same.
    final milk = MilkFeed.shared;
    if (milk.running) {
      milk.tick(_state);
      // A favourite's preset held: the director's cuts wait until it is let go.
      if (_faveOn?.milk == null) {
        milk.director.frame(_state, said);
      } else {
        _faveMilk(milk);
      }
      final on = milk.preset?.fullName;
      if (on != _macros.milkPreset) {
        _macros = _macros.copyWith(milkPreset: on, clearMilkPreset: on == null);
        _state = _state.copyWith(macros: _macros);
      }
    }
    notifyListeners();
    for (final e in said) {
      _events.add(e);
    }
  }

  static ShowState _blank(DateTime now) => ShowState(now: now, a: const ShowDeck(name: 'A'), b: const ShowDeck(name: 'B'));

  @override
  void dispose() {
    stop();
    if (_saving != null) {
      _saving!.cancel();
      _saving = null;
      unawaited(store.save(_doc));
    }
    source.dispose();
    unawaited(_events.close());
    super.dispose();
  }
}

/// A track's words for the engine, where a test wants to hand them in.
extension ShowTrackWords on Track {
  String get showArtist => artists.join(', ');
}

/// The show as the sets' shelf sees it: the pool's set, the document's snapshots,
/// the booth's server.
class _SnapshotHost implements SnapshotHost {
  _SnapshotHost(this.show);
  final ShowEngine show;

  @override
  ShowSetup get setup => show.pool.setup;
  @override
  List<ShowSnapshot> get kept => show.doc.snapshots;
  @override
  ShowSnapshot? get taken => show.doc.snapshot;
  @override
  ApiClient get api => show.source.api;
  @override
  ShowSetup fromLegacy(List<dynamic> rules) => show.setupFromLegacy(rules);

  @override
  void put({ShowSetup? setup, List<ShowSnapshot>? kept, ShowSnapshot? taken, bool clearTaken = false}) {
    final d = show.doc;
    show.setDoc(d.copyWith(pool: setup == null ? null : d.pool.withSetup(setup), snapshots: kept, snapshot: taken, clearSnapshot: clearTaken));
  }
}

/// Something the hands hold (show_engine.dart's holds): the look on (HOLD, a
/// combination or a favourite put on), a background held under everything, an effect
/// over everything, MilkDrop's preset, a change waiting for its moment.
enum ShowHold { look, ground, effect, preset, pending }
