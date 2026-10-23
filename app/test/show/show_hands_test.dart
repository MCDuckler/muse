// The hands on the show: the director's combination on the frame, one played and
// held, a background held, a launch landing on its moment, the pool's rules and
// switches reaching the director and the dancers.
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/deck.dart';
import 'package:muse/src/state/booth/mixer.dart';
import 'package:muse/src/state/show/show_director.dart';
import 'package:muse/src/state/show/show_engine.dart';
import 'package:muse/src/state/show/show_pool.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/state/show/show_tune.dart';
import 'package:muse/src/state/show/show_state.dart' show ShowMacros;
import 'package:muse/src/state/show/show_store.dart';

import '../fake_audio.dart';

TrackTiming grid(int ms) => TrackTiming(
      durationMs: 60000,
      bpm: 60000 / ms,
      beats: [for (var t = 0; t < 60000; t += ms) t],
      downbeats: [for (var t = 0; t < 60000; t += 4 * ms) t],
      energy: [for (var i = 0; i < 29; i++) 128],
    );

Track song(int id) => Track.fromJson({
      'id': id,
      'title': 'Song $id',
      'artists': ['Someone'],
      'duration_ms': 60000,
      'state': 'ready',
      'stream_url': '/tracks/$id/stream',
      'source': 'youtube',
      'cover_color': '#ff0000',
    });

class QuietMixer extends Mixer {
  @override
  bool get canKill => true;
  @override
  bool get canFilter => true;
  @override
  Future<void> setLevels(Map<Deck, double> levels, {Duration over = Duration.zero}) async {}
  @override
  Future<void> setEq(Deck deck, EqSet eq) async {}
  @override
  Future<void> setFilter(Deck deck, double value) async {}
}

const kinetic = Look(
  id: 'kinetic',
  name: 'Kinetic',
  rig: ShowRig(figure: RigFigure(kind: Figure.kinetic), finish: RigFinish(trails: 0.35, bloom: 0.9)),
  meta: SceneMeta(id: 'kinetic', priority: 2),
  shipped: true,
);
const flash = Look(
  id: 'flash',
  name: 'Flash',
  rig: ShowRig(figure: RigFigure(kind: Figure.flash), finish: RigFinish(bloom: 0.25)),
  meta: SceneMeta(id: 'flash'),
  shipped: true,
);
const dancers = Look(
  id: 'dance-art',
  name: 'Dancer',
  rig: ShowRig(figure: RigFigure(kind: Figure.dancers, dressing: Dressing.none)),
  meta: SceneMeta(id: 'dance-art'),
  shipped: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Booth booth;
  late ShowEngine show;
  late MemoryShowStore store;

  setUp(() async {
    // One session's number, so the director's turns and the blends' ways are the same each run.
    ShowEngine.seedForTests = 3;
    JustAudioPlatform.instance = FakeJustAudio();
    store = MemoryShowStore();
    booth = Booth(ApiClient(baseUrl: 'http://example.invalid')..token = 'x', mixer: QuietMixer(), showStore: store);
    await booth.init();
    booth.timing.put(1, grid(500));
    show = booth.show;
    show.looks = {for (final l in [kinetic, flash, dancers]) l.id: l};
    show.director.scenes = [kinetic.meta, flash.meta, dancers.meta];
  });

  tearDown(() => booth.dispose());

  test('the frame carries the look on in the director\'s combination', () {
    final t = DateTime(2026, 1, 1);
    show.chooseScene('kinetic');
    show.tick(t);
    expect(show.state.scene, 'kinetic');
    expect(show.state.rig.figure.kind, Figure.kinetic);
    final c = show.combo!;
    expect(c.scene, 'kinetic');
    expect(show.state.rig.ground, groundOfKey(c.ground));
    expect(show.state.rig.blend, RigBlend(mask: c.mask, mix: c.mix));
    expect(c.ground, isNot('camera'), reason: 'no camera on');
    expect(c.ground, isNot('cover'), reason: 'no record\'s cover');
    expect(show.pool.weightOf(c), greaterThan(0));
    expect(show.state.rig.finish.trails, 0.35, reason: 'the look\'s own finish');
  });

  test('a combination played is on as it is and held; a background held; the finish and the strength the hands\'', () {
    final t = DateTime(2026, 1, 1);
    show.chooseScene('flash');
    show.tick(t);
    const c = Combo(ground: 'white', scene: 'kinetic', style: 'ascii', mask: Mask.inverted, mix: Mix.contrast);
    show.play(c);
    expect(show.sceneHeld, isTrue);
    for (var i = 1; i < 20; i++) {
      show.tick(t.add(Duration(milliseconds: 16 * i)));
    }
    expect(show.state.scene, 'kinetic');
    expect(show.combo, c);
    expect(show.state.rig.ground.kind, Ground.white);
    expect(show.state.rig.figure.treatment, Treatment.ascii);
    expect(show.state.rig.blend, const RigBlend(mask: Mask.inverted, mix: Mix.contrast));
    // Let go, a background held: the director keeps to it.
    show.holdScene(false);
    show.holdGround('wash');
    show.tick(t.add(const Duration(milliseconds: 400)));
    expect(show.combo!.ground, 'wash');
    expect(show.state.rig.ground.kind, Ground.wash);
    show.holdGround(null);
    expect(show.heldGround, isNull);
    // The finish over every scene, and how strong the blend is.
    show.setFinish(const RigFinish(trails: 0.6));
    show.setBlendStrength(0.5);
    show.tick(t.add(const Duration(milliseconds: 416)));
    expect(show.state.rig.finish.trails, 0.6);
    expect(show.state.rig.blend.strength, 0.5);
    show.setFinish(null);
    show.tick(t.add(const Duration(milliseconds: 432)));
    expect(show.state.rig.finish.trails, 0.35);
  });

  test("the transformation: held by the hands, or the director's — none most of the time — and the working size's switch with the frame", () {
    final t = DateTime(2026, 1, 1);
    show.chooseScene('kinetic');
    // Held: what the hands say, over every combination.
    show.setTransform(const TransformSet(mode: TransformMode.both, count: 3, differ: 0.4, turn: 0.25, line: 0.5));
    show.setAdapt(false);
    show.tick(t);
    expect(show.state.rig.transform, const RigTransform(count: 3, differ: 0.4, slit: true, turn: 0.25, line: 0.5, blend: Mix.screen, amount: 0.85));
    expect(show.state.macros.adapt, isFalse);
    show.chooseScene('flash');
    show.tick(t.add(const Duration(milliseconds: 16)));
    expect(show.state.rig.transform.count, 3, reason: 'over whatever is on');
    final back = ShowPool.fromJson(show.pool.toJson());
    expect(back.transform, show.pool.transform);
    expect(back.adapt, isFalse);
    // The director's, never: none.
    show.setTransform(const TransformSet(often: 0));
    show.chooseScene('kinetic');
    show.tick(t.add(const Duration(milliseconds: 32)));
    expect(show.state.rig.transform.any, isFalse);
    expect(show.transformOn, TransformMode.none);
    // The director's, always: one of the two, the same while the combination stays.
    show.setTransform(const TransformSet(often: 1));
    show.chooseScene('flash');
    show.tick(t.add(const Duration(milliseconds: 48)));
    expect(show.transformOn, isIn([TransformMode.kaleidoscope, TransformMode.slit]));
    final picked = show.state.rig.transform;
    expect(picked.any, isTrue);
    show.tick(t.add(const Duration(milliseconds: 64)));
    expect(show.state.rig.transform, picked);
    show.setTransform(TransformSet.standard);
    show.setAdapt(true);
    expect(show.pool.toJson().containsKey('transform'), isFalse);
  });


  test('a launch lands on the bar, now when nothing plays, and the pool says when', () async {
    final t = DateTime(2026, 1, 1);
    show.chooseScene('kinetic');
    show.tick(t);
    // Nothing playing: now.
    show.launch('flash');
    expect(show.pendingLook, isNull);
    expect(show.state.scene, 'flash');
    // A record playing (the fake deck's clock is the wall's): the launch waits for
    // the bar — two seconds at 120 — and lands on it, on a cut.
    await booth.load(booth.a, song(1));
    await booth.a.play();
    show.tick(DateTime.now());
    expect(show.state.master.playing, isTrue);
    show.launch('kinetic');
    expect(show.pendingLook, 'kinetic');
    expect(show.pendingAt, Quantise.bar);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    show.tick(DateTime.now());
    expect(show.state.scene, 'flash', reason: 'no bar yet');
    expect(show.pendingLook, 'kinetic');
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    show.tick(DateTime.now());
    expect(show.state.scene, 'kinetic');
    expect(show.pendingLook, isNull);
    expect(show.state.sceneK, 1, reason: 'a launch is a cut, not a dissolve');
    // The pool's quantise: now.
    show.setPool(show.pool.copyWith(quantise: Quantise.now));
    show.launch('flash');
    expect(show.state.scene, 'flash');
    expect(show.pendingLook, isNull);
    // Asked for the phrase, then thought better of it.
    show.launch('dance-art', at: Quantise.phrase);
    expect(show.pendingLook, 'dance-art');
    show.cancelLaunch();
    expect(show.pendingLook, isNull);
  }, tags: ['wall-clock']);

  test('a style\'s card at 0 is never picked; the moves reach the dancers', () async {
    final t = DateTime(2026, 1, 1);
    await show.ready();
    // Every dancer style off but the silhouettes.
    var p = show.pool;
    for (final st in stylesOfFigure(Figure.dancers)) {
      if (st != 'mono') p = p.withRule(ComboRule(styles: {st}), 0);
    }
    show.setPool(p);
    for (var round = 0; round < 6; round++) {
      show.chooseScene(round.isEven ? 'dance-art' : 'flash');
      show.tick(t.add(Duration(milliseconds: 16 * round)));
      if (show.state.scene == 'dance-art') expect(show.state.rig.figure.style, 'mono');
    }
    // The moves: the pool's switches and stars reach the dancers' statics.
    show.setPool(show.pool.withOff('move.long22', true).withLean('move.long30', 2));
    expect(MovePool.off, {'long22'});
    expect(MovePool.favourites, {'long30'});
    show.audition('long14');
    expect(MovePool.audition, 'long14');
    MovePool.audition = null;
  });

  test('the pool reaches the director and the dancers, and is kept', () async {
    await show.ready();
    show.setPool(show.pool.withScene('flash', false).withOff('dancer.joe', true).copyWith(dancer: 'chris'));
    expect(show.director.leans['flash'], 0);
    expect(show.director.on.map((s) => s.id), isNot(contains('flash')));
    expect(show.macros.dancersOff, ['joe']);
    expect(show.macros.dancer, 'chris');
    show.setPool(show.pool.copyWith(clearDancer: true));
    expect(show.macros.dancer, 'mix');
    // Kept a moment later.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(store.kept?.pool.sceneOn('flash'), isFalse);
    expect(store.kept?.pool.isOn('dancer.joe'), isFalse);
  });

  test('a scene through a treatment carries it on its frame, with the knobs; the dancers draw theirs as their style', () {
    final t = DateTime(2026, 1, 1);
    show.play(const Combo(ground: 'milk', scene: 'kinetic', style: 'lines'));
    show.setTune('lines', TuneKnob.weight, 2);
    show.tick(t);
    expect(show.state.rig.figure.treatment, Treatment.lines);
    expect(show.state.rig.figure.style, isNull, reason: 'kinetic has no style of its own: the stage pass draws it');
    expect(show.state.macros.tune['lines.weight'], 2);
    expect(ShowMacros.fromJson(show.state.macros.toJson()).tune['lines.weight'], 2, reason: 'over the wire to a stage of its own');
    // As drawn: no treatment.
    show.play(const Combo(ground: 'milk', scene: 'flash', style: 'raw'));
    show.tick(t.add(const Duration(milliseconds: 16)));
    expect(show.state.rig.figure.treatment, Treatment.auto);
    // The dancers draw it as their own style.
    show.play(const Combo(ground: 'milk', scene: 'dance-art', style: 'ascii'));
    show.tick(t.add(const Duration(milliseconds: 32)));
    expect(show.state.rig.figure.treatment, Treatment.auto);
    expect(show.state.rig.figure.style, 'ascii');
    show.setTune('lines', TuneKnob.weight, null);
    expect(show.pool.tune, isEmpty);
    expect(tuneOf(show.pool.tune, 'lines', TuneKnob.weight), 1);
  });
}
