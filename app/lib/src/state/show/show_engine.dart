// The show's engine: the booth read once a frame into a ShowState, and the edges
// between frames said as events.
//
// Runs while the booth is open (BoothClock starts and stops it), on a ticker of its
// own at the screen's rate. Each tick reads the decks' clocks as the ear hears them
// (the time-stretcher's delay taken off, the performer's offset added), what the
// analysis says of that moment (show_deck.dart), the mixer's settings and the mix
// in progress, eases the palette towards the record's, decays the hit, and hands
// the frame on. Everything downstream — the stage, the lights, a recording — reads
// [state] and [events] and nothing else.
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../../api/models.dart';
import '../../audio/engine.dart';
import '../booth/booth.dart';
import '../booth/deck.dart';
import 'show_deck.dart';
import 'show_director.dart';
import 'show_dynamics.dart';
import 'show_events.dart';
import 'camera_feed.dart';
import 'milk_feed.dart';
import 'show_feed.dart';
import 'show_genome.dart';
import 'show_heard.dart';
import 'show_palette.dart';
import 'show_pool.dart';
import 'show_rig.dart';
import 'show_tune.dart';
import 'show_state.dart';
import 'show_store.dart';

class ShowEngine extends ChangeNotifier implements ShowFeed {
  ShowEngine(this.booth, {ShowStore? store}) : store = store ?? ShowStore.forThisDevice() {
    booth.stepApplied.addListener(_stepSaid);
    booth.fxFired.addListener(_fxSaid);
    _state = _blank(DateTime.now());
    _macros = _macros.copyWith(seed: seed);
    // MilkDrop's sound: the record's file here, or its stream.
    MilkFeed.shared.pcm.source = (id) {
      final local = booth.a.offlinePath?.call(id);
      if (local != null) return (url: local, headers: const <String, String>{});
      final track = booth.a.track?.id == id
          ? booth.a.track
          : booth.b.track?.id == id
              ? booth.b.track
              : null;
      if (track == null) return null;
      return (url: booth.api.streamUrl(track), headers: booth.api.streamHeaders);
    };
    // Or, where the booth plays on its own engine, what the room hears.
    MilkFeed.shared.pcm.heard = _heardPcm;
  }

  final Booth booth;

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
    director.grounds = _groundPool;
    director.allowed = _allowed;
  }

  /// The family a look belongs to, for the director's turns: geometric shapes,
  /// figures in a space, organic simulations, media.
  static String familyOf(Figure f, Ground g) => switch (f) {
        Figure.kinetic || Figure.blocks || Figure.flash || Figure.glide => 'geometric',
        Figure.dancers || Figure.birds || Figure.turntable => 'figurative',
        Figure.fluid || Figure.veins || Figure.field => 'organic',
        Figure.meme || Figure.words || Figure.room => 'media',
        Figure.none => 'organic',
      };

  /// The grounds the director may put under a scene, weighted: MilkDrop most of the
  /// time (the booth's way), the rest sharing what is left; each one the pool has
  /// on (show_pool.dart's `ground.*`), the room only with a camera on. None on is
  /// black under every scene.
  List<(RigGround, double)> _groundPool() {
    final p = pool;
    final out = <(RigGround, double)>[];
    if (p.isOn('ground.milk')) out.add((RigGround.milk, 4));
    if (p.isOn('ground.wash')) out.add((const RigGround(kind: Ground.wash), 1));
    if (p.isOn('ground.pulse')) {
      for (final v in pulseVariants) {
        out.add((RigGround(kind: Ground.pulse, field: v), 0.45));
      }
    }
    if (p.isOn('ground.cover')) out.add((const RigGround(kind: Ground.cover, dim: 0.6), 0.6));
    if (p.isOn('ground.field')) out.add((const RigGround(kind: Ground.field, field: 'drift', dim: 0.6), 0.6));
    if (p.isOn('ground.camera') && (_state['cam.on']) > 0.5) out.add((const RigGround(kind: Ground.camera, dim: 0.8), 1));
    // How often the hands want each: their lean on its weight.
    return [for (final (g, w) in out) (g, w * p.leanOf('ground.${g.kind.name}'))];
  }

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
    }();
  }

  void _apply(ShowDoc doc) {
    _doc = doc;
    director.off = doc.pool.looksOff;
    director.leans = {for (final e in doc.pool.lean.entries) if (e.key.startsWith('look.')) e.key.substring(5): e.value};
    director.bias = doc.pool.bias;
    MovePool.from(doc.pool);
    StylePool.from(doc.pool);
    QualityPool.from(doc.pool);
    director.allowed = _allowed;
    director.grounds = _groundPool;
    // The dancers still read who dances off the hands' macros.
    _macros = _macros.copyWith(dancer: doc.pool.dancer ?? 'mix', dancersOff: doc.pool.dancersOff, tune: doc.pool.tune);
    if (!running) tick(DateTime.now());
    notifyListeners();
  }

  Timer? _saving;

  /// The hands changed the pool: applied now, kept a moment later.
  void setPool(ShowPool p) => setDoc(_doc.copyWith(pool: p));

  void setDoc(ShowDoc d) {
    _apply(d);
    _saving?.cancel();
    _saving = Timer(const Duration(milliseconds: 300), () {
      _saving = null;
      unawaited(store.save(_doc));
    });
  }

  // ------------------------------------------------------------------ the hands' rig
  /// The hands' own layers (show_rig.dart), taken where locked: the ground, the
  /// blend and the finish over whatever look the director has on. The figure's lock
  /// is the director's hold (holdScene).
  ShowRig _hands = ShowRig.none;
  ShowRig get hands => _hands;
  bool locked(RigSlot slot) => slot == RigSlot.figure ? director.locked : _hands.locked(slot);

  /// The hands' ground, locked (the director leaves it) unless [lock] is false.
  void setGround(RigGround g, {bool lock = true}) => _setHands(_hands.copyWith(ground: g).withLock(RigSlot.ground, lock));

  /// The hands' blend; unlocked, the look's and the pool's table decide again.
  void setBlend(RigBlend b, {bool lock = true}) => _setHands(_hands.copyWith(blend: b.copyWith(auto: !lock)).withLock(RigSlot.blend, lock));

  void setFinish(RigFinish f, {bool lock = true}) => _setHands(_hands.copyWith(finish: f).withLock(RigSlot.finish, lock));

  /// A layer locked takes the rig as it is now and keeps it; unlocked, the director
  /// and the look have it again.
  void lock(RigSlot slot, bool on) {
    if (slot == RigSlot.figure) return holdScene(on);
    var h = _hands;
    if (on && !h.locked(slot)) {
      final r = _state.rig;
      h = switch (slot) {
        RigSlot.ground => h.copyWith(ground: r.ground),
        RigSlot.blend => h.copyWith(blend: r.blend.copyWith(auto: false)),
        RigSlot.finish => h.copyWith(finish: r.finish),
        RigSlot.figure => h,
      };
    }
    _setHands(h.withLock(slot, on));
  }

  void _setHands(ShowRig h) {
    _hands = h;
    if (!running) tick(DateTime.now());
    notifyListeners();
  }

  /// The figure's own named look the hands asked for (a dancer's art, a flock's
  /// look), for figures of [forKind]; null lets the figure's clock choose again.
  String? _style;
  Figure? _styleFor;
  String? get style => _style;
  Figure? get styleFor => _styleFor;
  void setStyle(String? style, {Figure? forKind}) {
    _style = style;
    _styleFor = style == null ? null : forKind;
    if (!running) tick(DateTime.now());
    notifyListeners();
  }

  /// [look] put through [treatment] whenever it is on (`raw`: none; null: the
  /// conductor's mix), kept.
  void setTreat(String look, String? treatment) => setPool(pool.withTreat(look, treatment));

  /// A treatment's knob, kept (null: back to its rest).
  void setTune(String treatment, TuneKnob k, double? v) => setPool(pool.withTune(tuneKey(treatment, k), v));

  /// A move asked for by hand: the lead dances it at the next slot.
  void audition(String moveId) {
    MovePool.audition = moveId;
    notifyListeners();
  }

  /// [rig] with the hands' layers where they are locked, and their style; the
  /// treatment the hands put on [look] (the pool's), or the conductor's. A look that
  /// is its own whole picture (MilkDrop alone) keeps its ground; any other stands on
  /// the hands' ground where locked, else the director's (the pool's grounds,
  /// rotated), else black. A pair the rules call never — the hands' style, or the
  /// figure's own clock — goes onto black rather than break the rule.
  ShowRig _withHands(ShowRig rig, {String? look}) {
    var figure = _style != null && rig.figure.kind == _styleFor ? rig.figure.copyWith(style: _style) : rig.figure;
    final treat = look == null ? null : _treatFor(look, figure.kind);
    if (treat != null && figure.kind != Figure.none) {
      figure = figure.copyWith(treatment: treat);
      // The birds, and the dancers on their stylised stage, have the image
      // treatments as styles of their own, drawn better than a pass over the frame
      // can (the figure lit for it, the glyphs popping from its middle): theirs,
      // unless the hands picked them a style already. The rest go through the
      // stage's pass (ui/show/show_canvas.dart).
      final own = figure.kind == Figure.birds || (figure.kind == Figure.dancers && look == 'dance-art');
      if (own && imageTreatments.contains(treat) && !(_style != null && figure.kind == _styleFor)) figure = figure.copyWith(style: treat.name);
    }
    final whole = figure.kind == Figure.none;
    final handsGround = !whole && _hands.locked(RigSlot.ground);
    var ground = whole
        ? rig.ground
        : handsGround
            ? _hands.ground
            : rig.ground.kind != Ground.black
                ? rig.ground
                : (director.ground ?? RigGround.black);
    final looked = ShowPool.lookupFigure(figure);
    if (!whole && !handsGround && ground.kind != Ground.black && pool.answer(looked, ground.kind).never) {
      // Never together: the scene on another of the director's backgrounds (the most
      // likely one it goes with), else on black — it still plays.
      final others = _groundPool()..sort((a, b) => b.$2.compareTo(a.$2));
      ground = others.map((o) => o.$1).where((g) => !pool.answer(looked, g.kind).never).firstOrNull ?? RigGround.black;
    }
    StylePool.ground = ground.kind;
    // The blend: the hands' where locked; else the rules' for this figure on this
    // ground (contrast under MilkDrop and as the default; a shape on the pulse adds…).
    // A shipped rule's way is picked by the pair, the record and the session.
    // (A hash of its own: Object.hash is seeded afresh each run.)
    var blendSeed = 0x811c9dc5;
    for (final c in '$look|${looked.style}|${ground.kind.name}|${_state.master.trackId}|$seed'.codeUnits) {
      blendSeed = ((blendSeed ^ c) * 0x01000193) & 0x7fffffff;
    }
    final blend =
        _hands.locked(RigSlot.blend) && !whole ? _hands.blend : (whole ? rig.blend : pool.blendFor(looked, ground.kind, from: rig.blend, seed: blendSeed));
    return rig.copyWith(
      ground: ground,
      figure: figure,
      blend: blend,
      finish: _hands.locked(RigSlot.finish) ? _hands.finish : rig.finish,
      locks: {..._hands.locks, if (director.locked) RigSlot.figure},
    );
  }

  /// The treatment [look] goes through now: the one the hands put on it, none where
  /// they said off, and where they left it to the mix (as every look starts), the
  /// conductor's — one of the treatments in that look's own mix (or the look as
  /// drawn, which counts twice), chosen afresh every [treatBars] bars of the record,
  /// the same for the same record, look and bars. Words and memes are left as they
  /// are by the mix (the hands can still put them through one).
  Treatment? _treatFor(String look, Figure kind) {
    final say = pool.treat[look];
    if (say == 'raw') return null;
    // One the hands put on, unless they switched it off since (gone everywhere).
    if (say != null && say != 'mix') return pool.isOn('treatment.$say') ? Treatment.values.asNameMap()[say] : null;
    if (kind == Figure.none || kind == Figure.words || kind == Figure.meme) return null;
    // A figure whose styles these are (the dancers, the birds): their own how often
    // over each (never, rarely, often), as their clock reads it.
    final styled = kind == Figure.dancers || kind == Figure.birds;
    final options = [
      for (final (t, w) in treatMix(pool, look))
        if (!styled || t == Treatment.raw || pool.styleOn(kind, t.name))
          (t, styled && t != Treatment.raw ? w * pool.leanOf('style.${kind.name}.${t.name}') : w),
    ];
    if (options.isEmpty) return null;
    final m = _state.master;
    final slot = (m.barIndex ?? 0) ~/ treatBars;
    var h = 0x811c9dc5;
    for (final c in '$look:${m.trackId ?? 0}:$slot:$seed'.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0x7fffffff;
    }
    final total = options.fold<double>(0, (a, o) => a + o.$2);
    var at = (h % 10007) / 10007 * total;
    for (final (t, w) in options) {
      at -= w;
      if (at < 0) return t == Treatment.raw ? null : t;
    }
    return null;
  }

  /// How many bars the conductor keeps a treatment on a look.
  static const treatBars = 8;

  /// Whether the pool lets the director put [id] on: MilkDrop alone only where
  /// MilkDrop is on and the hands keep no other background; a figure where the
  /// rules let it stand on the ground it would have.
  bool _allowed(String id) {
    final look = looks[id];
    if (look == null) return true;
    final r = look.rig;
    if (r.figure.kind == Figure.none) {
      if (r.ground.kind != Ground.milk) return true;
      return pool.isOn('ground.milk') && !(_hands.locked(RigSlot.ground) && _hands.ground.kind != Ground.milk);
    }
    // Any other may go on: where the rules keep it off the background, it is put on
    // another (_withHands), not left out.
    return true;
  }

  // ------------------------------------------------------------------ launches
  /// A look the hands asked for, landing on the next beat, bar or phrase of the
  /// master (the pool's quantise, or [at]) — or now, and now when nothing plays.
  ({String look, Quantise at, DateTime asked})? _launch;
  String? get pendingLook => _launch?.look;
  Quantise? get pendingAt => _launch?.at;

  void launch(String id, {Quantise? at}) {
    if (!looks.containsKey(id) && !director.scenes.any((s) => s.id == id)) return;
    final q = at ?? pool.quantise;
    if (q == Quantise.now || !_state.master.playing) {
      director.choose(id, how: SceneChange.cut);
      _launch = null;
    } else {
      _launch = (look: id, at: q, asked: DateTime.now());
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
    director.choose(l.look, how: SceneChange.cut);
    _launch = null;
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

  /// WETOWL_SHOW_SOUND=pulse: the house's pulse through the mixer model even where
  /// the engine could say what is heard (to compare the two).
  static final _pulseOnly = !kIsWeb && Platform.environment['WETOWL_SHOW_SOUND'] == 'pulse';

  /// What the engine hears, where the booth plays on it (show_heard.dart).
  ShowHeard? _heard;
  ShowHeard? get _heardNow {
    final e = Engine.started;
    if (e == null || _pulseOnly) return _heard = null;
    if (_heard?.engine != e) _heard = ShowHeard(e);
    return _heard;
  }

  /// MilkDrop's sound off the engine: the master's samples since the last tick.
  double? _pcmAt;
  Int16List? _heardPcm() {
    final e = Engine.started;
    if (e == null || _pulseOnly || !(booth.a.onEngine || booth.b.onEngine)) return null;
    final at = e.now() + math.min(e.latency, ShowHeard.maxLead);
    var from = _pcmAt;
    if (from == null || from > at || at - from > 0.25) from = at - 1 / 60;
    final n = ((at - from) * e.rate).round();
    if (n <= 0) return null;
    _pcmAt = from + n / e.rate;
    final x = e.scope(Engine.master, _pcmAt!, n);
    if (x == null) return null;
    final out = Int16List(n);
    for (var i = 0; i < n; i++) {
      out[i] = (x[i] * 32767).round().clamp(-32768, 32767);
    }
    return out;
  }

  /// Said by the booth between frames, told on the next.
  final _pending = <ShowEvent>[];
  final _askedVocals = <int>{};

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
    director.next();
  }

  void previousScene() {
    if (milkOnly) return MilkFeed.shared.director.previous();
    _launch = null;
    director.next(by: -1);
  }

  /// The next scene the director may use, whatever is held (a scene just switched
  /// off steps on to one that is on).
  void stepOn() {
    _launch = null;
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
    director.choose(id);
  }

  /// The scene on held: the director's rules stay off it until it is let go (the
  /// arrows still move it, and the next one is held instead). One look as a mode.
  bool get sceneHeld => director.locked;
  void holdScene(bool on) {
    _launch = null;
    director.locked = on;
    if (!on) _milkOnly = false;
    if (!running) tick(DateTime.now());
    notifyListeners();
  }

  void _stepSaid() {
    final s = booth.stepApplied.last;
    if (s == null) return;
    _pending.add(ShowEvent(ShowEventKind.step, DateTime.now(), data: {'at': s.at, 'crossfader': s.crossfader}));
  }

  void _fxSaid() {
    final f = booth.fxFired.last;
    if (f == null) return;
    _pending.add(ShowEvent(ShowEventKind.fx, DateTime.now(), data: {'sound': f.sound.name, 'beats': f.beats}));
  }

  // ------------------------------------------------------------------ the frame
  /// One frame, at [now]. Public for a test; the ticker calls it.
  void tick(DateTime now) {
    final last = _last;
    final dt = last == null ? 0.0 : now.difference(last).inMicroseconds / 1e6;
    _last = now;
    final prev = _state;

    final levels = booth.levels;
    var a = _deck(booth.a, now, levels.a);
    var b = _deck(booth.b, now, levels.b);

    // The sound as heard, where the decks play on the engine: each deck's own, and
    // the room's; the stems' levels stay the pulse's.
    var audio = a.audio + b.audio;
    final live = <String, double>{};
    final heardBy = _heardNow;
    final ai = booth.a.engineIndex, bi = booth.b.engineIndex;
    if (heardBy != null && (ai != null || bi != null)) {
      final h = heardBy.read([if (ai != null) ai, if (bi != null) bi]);
      if (h != null) {
        if (h.decks[ai] case final ha?) a = a.withAudio(ShowHeard.over(ha, a.audio));
        if (h.decks[bi] case final hb?) b = b.withAudio(ShowHeard.over(hb, b.audio));
        audio = ShowHeard.over(h.master, audio);
        live['live.on'] = 1;
        final spec = h.spectrum;
        if (spec != null) {
          for (var i = 0; i < spec.length; i++) {
            live['spec.$i'] = spec[i];
          }
        }
      }
    }

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

    final m = booth.mixing;
    final arm = booth.arming;
    final mix = m != null
        ? ShowMix(on: true, kind: m.kind.name, from: m.from, to: m.to, bars: m.bars, k: m.k)
        : arm != null
            ? ShowMix(armed: true, kind: arm.kind.name, from: arm.from, to: arm.to, startsIn: arm.startsAt.difference(now))
            : ShowMix.none;

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
    _state = _state.copyWith(
      scene: d.scene,
      sceneFrom: d.from,
      sceneK: d.k,
      clearSceneFrom: d.from == null,
      rig: _withHands(look?.rig ?? ShowRig.none, look: look?.id),
      rigFrom: leaving == null ? null : _withHands(leaving.rig, look: leaving.id),
      macros: dark && !_macros.blackout ? _macros.copyWith(blackout: true) : _macros,
    );
    // MilkDrop, where it is on: the numbers and the sound, and its director's cuts;
    // the preset on goes over the wire, so a stage in another process shows the same.
    final milk = MilkFeed.shared;
    if (milk.running) {
      milk.tick(_state);
      milk.director.frame(_state, said);
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

  ShowDeck _deck(Deck deck, DateTime now, double level) {
    final track = deck.track;
    if (track == null) return ShowDeck(name: deck.name);
    // The ear's position: the engine's clock, less what the stretcher holds back,
    // plus the performer's offset.
    final at = deck.positionAt(now) - booth.mixer.stretchLatency(deck) + Duration(milliseconds: offsetMs);
    final timing = deck.timing ?? booth.timing.peek(track.id);
    var vocals = booth.vocals.peek(track.id);
    if (vocals == null && _askedVocals.add(track.id)) {
      unawaited(booth.vocals.of(track).then((_) => _askedVocals.remove(track.id)));
    }
    final pulse = booth.pulse[track.id];
    if (pulse == null) unawaited(booth.fetchPulse(track));
    return deriveDeck(
      name: deck.name,
      track: track,
      coverUrl: booth.api.coverUrl(track),
      streamUrl: booth.api.streamUrl(track),
      playing: deck.playing,
      position: at < Duration.zero ? Duration.zero : at,
      timing: timing,
      vocals: vocals,
      pulse: pulse,
      channel: ChannelSettings(
        level: level.clamp(0.0, 1.0),
        eq: booth.eqOf(deck),
        filter: booth.filters[deck] ?? 0,
        stems: deck.stemLevels,
        looping: deck.loopStart != null && deck.loopEnd != null,
      ),
    );
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
    booth.stepApplied.removeListener(_stepSaid);
    booth.fxFired.removeListener(_fxSaid);
    unawaited(_events.close());
    super.dispose();
  }
}

/// A track's words for the engine, where a test wants to hand them in.
extension ShowTrackWords on Track {
  String get showArtist => artists.join(', ');
}
