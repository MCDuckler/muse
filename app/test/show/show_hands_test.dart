// The hands on the rig: a layer locked is theirs, a launch lands on its moment,
// the pool's switches reach the director and the dancers.
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

  test('the frame carries the look on as its rig, MilkDrop under it the hands\' way', () {
    final t = DateTime(2026, 1, 1);
    show.chooseScene('kinetic');
    show.tick(t);
    expect(show.state.scene, 'kinetic');
    expect(show.state.rig.figure.kind, Figure.kinetic);
    expect(show.state.rig.ground.kind, Ground.milk, reason: 'milk under every scene is the default');
    expect(show.state.rig.blend.ground, GroundMode.contrast);
    expect(show.state.rig.finish.trails, 0.35);
    show.setMacros(show.macros.copyWith(milkUnder: false));
    show.tick(t.add(const Duration(milliseconds: 16)));
    expect(show.state.rig.ground.kind, Ground.black);
    expect(show.state.rig.blend.ground, GroundMode.over);
  });

  test('a layer locked is the hands\', and let go is the look\'s again', () {
    final t = DateTime(2026, 1, 1);
    show.chooseScene('kinetic');
    show.tick(t);
    show.setGround(const RigGround(kind: Ground.wash));
    show.tick(t.add(const Duration(milliseconds: 16)));
    expect(show.state.rig.ground.kind, Ground.wash);
    expect(show.state.rig.locked(RigSlot.ground), isTrue);
    expect(show.locked(RigSlot.ground), isTrue);
    // The look changes; the ground stays the hands'.
    show.chooseScene('flash');
    show.tick(t.add(const Duration(milliseconds: 32)));
    expect(show.state.scene, 'flash');
    expect(show.state.rig.ground.kind, Ground.wash);
    expect(show.state.rig.finish.bloom, 0.25, reason: 'the finish is the look\'s');
    // The blend and the finish locked as they are, then changed.
    show.lock(RigSlot.finish, true);
    show.setFinish(show.hands.finish.copyWith(bloom: 1.2));
    show.setBlend(const RigBlend(ground: GroundMode.window, figure: FigureMode.same));
    show.tick(t.add(const Duration(milliseconds: 48)));
    expect(show.state.rig.finish.bloom, 1.2);
    expect(show.state.rig.blend.ground, GroundMode.window);
    expect(show.state.rig.blend.figure, FigureMode.same);
    expect(show.state.rig.blend.auto, isFalse);
    expect(show.state.rig.locks, {RigSlot.ground, RigSlot.blend, RigSlot.finish});
    // Let go: the look's and the hands' macros again.
    show.lock(RigSlot.ground, false);
    show.lock(RigSlot.blend, false);
    show.lock(RigSlot.finish, false);
    show.tick(t.add(const Duration(milliseconds: 64)));
    expect(show.state.rig.ground.kind, Ground.milk);
    expect(show.state.rig.blend.ground, GroundMode.contrast);
    expect(show.state.rig.finish.bloom, 0.25);
    expect(show.state.rig.locks, isEmpty);
    // The figure's lock is the director's hold.
    show.lock(RigSlot.figure, true);
    show.tick(t.add(const Duration(milliseconds: 80)));
    expect(show.sceneHeld, isTrue);
    expect(show.state.rig.locked(RigSlot.figure), isTrue);
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

  test('a style holds for its figure only, and the rules keep a pair apart', () async {
    final t = DateTime(2026, 1, 1);
    // No treatment from the conductor's mix meanwhile: the styles alone.
    show.setTreat('dance-art', 'raw');
    show.chooseScene('dance-art');
    show.setStyle('ascii', forKind: Figure.dancers);
    show.tick(t);
    expect(show.state.rig.figure.style, 'ascii');
    show.chooseScene('kinetic');
    show.tick(t.add(const Duration(milliseconds: 16)));
    expect(show.state.rig.figure.style, isNull, reason: 'kinetic is no dancer');
    show.setStyle(null);
    show.chooseScene('dance-art');
    show.tick(t.add(const Duration(milliseconds: 32)));
    expect(show.state.rig.figure.style, isNull);
    // The table: flash never on milk → the director passes flash by, under milk.
    await show.ready();
    expect(show.director.on.map((s) => s.id), contains('flash'));
    show.setPool(show.pool.withCombo('figure.flash|ground.milk', ComboRule.never));
    expect(show.director.on.map((s) => s.id), isNot(contains('flash')));
    // No milk under: together again.
    show.setMacros(show.macros.copyWith(milkUnder: false));
    expect(show.director.on.map((s) => s.id), contains('flash'));
    // The moves: the pool's switches and stars reach the dancers' statics.
    show.setPool(show.pool.withOff('move.long22', true).withLean('move.long30', 2));
    expect(MovePool.off, {'long22'});
    expect(MovePool.favourites, {'long30'});
    show.audition('long14');
    expect(MovePool.audition, 'long14');
    MovePool.audition = null;
  });

  test('the director\'s ground goes under the look, with the rules\' blend', () async {
    final t = DateTime(2026, 1, 1);
    await show.ready();
    show.chooseScene('kinetic');
    show.tick(t);
    expect(show.state.rig.ground.kind, Ground.milk);
    expect(show.state.rig.blend.ground, GroundMode.contrast);
    // The pool with MilkDrop off: the director's grounds are the rest; a shape adds.
    show.setPool(show.pool.withOff('ground.milk', true).withOff('ground.cover', true).withOff('ground.field', true).withOff('ground.camera', true).withOff('ground.wash', true));
    show.tick(t.add(const Duration(milliseconds: 16)));
    expect(show.state.rig.ground.kind, Ground.pulse);
    expect(show.state.rig.blend.ground, GroundMode.add);
    expect(show.state.rig.blend.auto, isTrue);
    // The hands' ground wins over the director's.
    show.setGround(const RigGround(kind: Ground.wash));
    show.tick(t.add(const Duration(milliseconds: 32)));
    expect(show.state.rig.ground.kind, Ground.wash);
    // MilkDrop off by the macros: black, as it was.
    show.lock(RigSlot.ground, false);
    show.setMacros(show.macros.copyWith(milkUnder: false));
    show.tick(t.add(const Duration(milliseconds: 48)));
    expect(show.state.rig.ground.kind, Ground.black);
  });

  test('the pool reaches the director and the dancers, and is kept', () async {
    await show.ready();
    show.setPool(show.pool.withOff('look.flash', true).withOff('dancer.joe', true).copyWith(dancer: 'chris'));
    expect(show.director.off, {'flash'});
    expect(show.macros.dancersOff, ['joe']);
    expect(show.macros.dancer, 'chris');
    show.setPool(show.pool.copyWith(clearDancer: true));
    expect(show.macros.dancer, 'mix');
    // Kept a moment later.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(store.kept?.pool.isOn('look.flash'), isFalse);
    expect(store.kept?.pool.isOn('dancer.joe'), isFalse);
    expect(store.kept?.pool.isOn('treatment.contour'), isFalse, reason: 'shipped off');
  });
  test('a scene put through a treatment carries it on its frame, with the knobs; the dancers take it as their style', () {
    final t = DateTime(2026, 1, 1);
    show.chooseScene('kinetic');
    show.setTreat('kinetic', 'lines');
    show.setTune('lines', TuneKnob.weight, 2);
    show.tick(t);
    expect(show.state.rig.figure.treatment, Treatment.lines);
    expect(show.state.rig.figure.style, isNull, reason: 'kinetic has no style of its own: the stage pass draws it');
    expect(show.state.macros.tune['lines.weight'], 2);
    expect(ShowMacros.fromJson(show.state.macros.toJson()).tune['lines.weight'], 2, reason: 'over the wire to a stage of its own');
    // Another scene, off, is as it draws itself.
    show.setTreat('flash', 'raw');
    show.chooseScene('flash');
    show.tick(t.add(const Duration(milliseconds: 16)));
    expect(show.state.rig.figure.treatment, Treatment.auto);
    // The stylised dancers draw it as their own style.
    show.setTreat('dance-art', 'ascii');
    show.chooseScene('dance-art');
    show.tick(t.add(const Duration(milliseconds: 32)));
    expect(show.state.rig.figure.treatment, Treatment.ascii);
    expect(show.state.rig.figure.style, 'ascii');
    // Kept.
    expect(ShowPool.fromJson(show.pool.toJson()).treat, {'kinetic': 'lines', 'flash': 'raw', 'dance-art': 'ascii'});
    show.setTune('lines', TuneKnob.weight, null);
    expect(show.pool.tune, isEmpty);
    expect(tuneOf(show.pool.tune, 'lines', TuneKnob.weight), 1);
  });
  test('left to the mix, a scene goes through what the conductor picks of its own mix, the same for the same bars', () {
    final t = DateTime(2026, 1, 1);
    show.chooseScene('kinetic');
    // Everything out of kinetic's mix but the dither: the dither it is.
    var p = show.pool;
    for (final x in [Treatment.raw, ...imageTreatments]) {
      p = withInMix(p, 'kinetic', x.name, x == Treatment.dither);
    }
    show.setPool(p);
    show.tick(t);
    expect(show.state.rig.figure.treatment, Treatment.dither);
    // Kinetic's mix is its own: flash still has the whole shipped one.
    expect(mixOf(show.pool, 'flash'), containsAll(['raw', 'ascii', 'dither', 'halftone', 'thermal', 'lines']));
    expect(mixOf(show.pool, 'kinetic'), ['dither']);
    expect(ShowPool.fromJson(show.pool.toJson()).mixes, {'kinetic': ['dither']}, reason: 'kept');
    // Only the look as drawn: none.
    p = withInMix(withInMix(p, 'kinetic', 'dither', false), 'kinetic', 'raw', true);
    show.setPool(p);
    show.tick(t.add(const Duration(milliseconds: 16)));
    expect(show.state.rig.figure.treatment, Treatment.auto);
    // The whole mix on: what it picks holds from frame to frame.
    for (final x in imageTreatments) {
      p = withInMix(p, 'kinetic', x.name, true);
    }
    show.setPool(p);
    show.tick(t.add(const Duration(milliseconds: 32)));
    final picked = show.state.rig.figure.treatment;
    for (var i = 3; i < 10; i++) {
      show.tick(t.add(Duration(milliseconds: 16 * i)));
      expect(show.state.rig.figure.treatment, picked);
    }
    expect(treatMix(p, 'kinetic').first, (Treatment.raw, 2.0), reason: 'as drawn counts twice');
  });

}
