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
    expect(show.pool.plan.lookWeight(c), greaterThan(0));
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

  test("the effect: the combination's, by the plan's effect row (none most of the time), or one held by the hands; the working size's switch with the frame", () {
    final t = DateTime(2026, 1, 1);
    show.chooseScene('kinetic');
    // Held: what the hands say, over every combination, with the knobs.
    show.setTransform(const TransformSet(count: 3, differ: 0.4, turn: 0.25, line: 0.5));
    show.holdFx(Fx.both);
    show.setAdapt(false);
    show.tick(t);
    expect(show.state.rig.transform, const RigTransform(count: 3, differ: 0.4, slit: true, turn: 0.25, line: 0.5, blend: Mix.screen, amount: 0.85));
    expect(show.state.macros.adapt, isFalse);
    show.chooseScene('flash');
    show.tick(t.add(const Duration(milliseconds: 16)));
    expect(show.state.rig.transform.count, 3, reason: 'over whatever is on');
    expect(show.holds, contains(ShowHold.effect));
    final back = ShowPool.fromJson(show.pool.toJson());
    expect(back.transform, show.pool.transform);
    expect(back.adapt, isFalse);
    show.holdFx(null);
    // The plan's: the combination on carries its effect, and the frame with it.
    show.play(const Combo(ground: 'white', scene: 'kinetic', style: 'raw', fx: Fx.mosh));
    show.tick(t.add(const Duration(milliseconds: 32)));
    expect(show.fxOn, Fx.mosh);
    expect(show.state.rig.transform.mosh, isTrue);
    expect(show.state.rig.transform.beforeStyle, isFalse);
    show.holdScene(false);
    // Every effect but none off: the director never puts one on.
    var p = show.pool.plan;
    for (final f in Fx.values) {
      if (f != Fx.none) p = p.withShared(PlanAxis.fx, f.name, muted: true);
    }
    show.setPlan(p);
    for (var i = 0; i < 12; i++) {
      show.chooseScene(i.isEven ? 'kinetic' : 'flash');
      show.tick(t.add(Duration(milliseconds: 48 + 16 * i)));
      expect(show.fxOn, Fx.none);
      expect(show.state.rig.transform.any, isFalse);
    }
    // The datamosh alone: always it.
    p = show.pool.plan.withShared(PlanAxis.fx, 'none', muted: true).withShared(PlanAxis.fx, 'mosh', muted: false);
    show.setPlan(p);
    show.chooseScene('kinetic');
    show.tick(t.add(const Duration(milliseconds: 400)));
    expect(show.fxOn, Fx.mosh);
    show.setTransform(TransformSet.standard);
    show.setAdapt(true);
    expect(show.pool.toJson().containsKey('transform'), isFalse);
  });

  test('everything held is said, let go one by one or all at once', () async {
    await show.ready();
    final t = DateTime(2026, 1, 1);
    show.chooseScene('kinetic');
    show.tick(t);
    expect(show.holds, isEmpty);
    show.play(const Combo(ground: 'white', scene: 'kinetic', style: 'raw'));
    show.holdGround('milk');
    show.holdFx(Fx.slit);
    expect(show.holds, [ShowHold.look, ShowHold.ground, ShowHold.effect]);
    show.letGo(ShowHold.ground);
    expect(show.heldGround, isNull);
    expect(show.holds, [ShowHold.look, ShowHold.effect]);
    show.letGoAll();
    expect(show.holds, isEmpty);
    expect(show.sceneHeld, isFalse);
    expect(show.heldFx, isNull, reason: 'the effect back to each look\'s own');
    // The finish and the blend's strength are kept now.
    show.setFinish(const RigFinish(trails: 0.5));
    show.setBlendStrength(0.4);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(store.kept?.pool.finish?.trails, 0.5);
    expect(store.kept?.pool.strength, 0.4);
  });

  test('a combination put on waits for the bar while a record plays, said as held', () async {
    show.chooseScene('flash');
    show.tick(DateTime.now());
    await booth.load(booth.a, song(1));
    await booth.a.play();
    show.tick(DateTime.now());
    expect(show.state.master.playing, isTrue);
    const c = Combo(ground: 'white', scene: 'kinetic', style: 'raw');
    show.play(c);
    expect(show.pendingCombo, c);
    expect(show.holds, contains(ShowHold.pending));
    expect(show.state.scene, 'flash');
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    show.tick(DateTime.now());
    expect(show.combo, c);
    expect(show.sceneHeld, isTrue);
    expect(show.pendingCombo, isNull);
    // Now, said so.
    show.play(const Combo(ground: 'black', scene: 'flash', style: 'raw'), at: Quantise.now);
    expect(show.state.scene, 'flash');
  }, tags: ['wall-clock']);

  test('the rules of before are read into the plan once the scenes are known, and kept', () async {
    final old = MemoryShowStore(ShowDoc.fromJson(const {
      'v': 1,
      'pool': {
        'combos': [
          {'scene': 'flash', 'weight': 0},
          {'ground': 'milk', 'weight': 4},
          {'ground': 'white', 'scene': 'kinetic', 'style': 'raw', 'weight': 0},
        ]
      },
      'snapshots': [
        {
          'id': 'l:1',
          'name': 'Calm',
          'rules': [
            {'scene': 'kinetic', 'weight': 0}
          ]
        }
      ],
    }));
    final b = Booth(ApiClient(baseUrl: 'http://example.invalid')..token = 'x', mixer: QuietMixer(), showStore: old);
    await b.init();
    final e = b.show;
    await e.ready();
    expect(e.pool.legacy, isNotNull, reason: 'the scenes not known yet');
    e.looks = {for (final l in [kinetic, flash, dancers]) l.id: l};
    expect(e.pool.legacy, isNull);
    expect(e.pool.before, hasLength(3));
    expect(e.pool.plan.sceneLevel('flash'), 0);
    expect(e.pool.plan.shared(PlanAxis.ground, 'milk'), 4);
    expect(e.pool.plan.lookWeight(const Combo(ground: 'white', scene: 'kinetic', style: 'raw')), 0);
    expect(e.doc.snapshots.single.legacy, isNull);
    expect(e.doc.snapshots.single.setup.plan.sceneLevel('kinetic'), 0);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(old.kept?.pool.legacy, isNull);
    expect(old.kept?.pool.plan.sceneLevel('flash'), 0);
    b.dispose();
  });
}
