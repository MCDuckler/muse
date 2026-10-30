// The favourites: what is on kept as it was (the combination, the framing, the 3D
// text's motion, look and bends), kept in the document, put back on held whatever the
// rules say, let go of by the hands; the framing held and the stage's own over the wire.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/deck.dart';
import 'package:muse/src/state/booth/mixer.dart';
import 'package:muse/src/state/show/show_director.dart';
import 'package:muse/src/state/show/show_engine.dart';
import 'package:muse/src/state/show/show_events.dart';
import 'package:muse/src/state/show/show_feed.dart';
import 'package:muse/src/state/show/show_pool.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/state/show/show_state.dart';
import 'package:muse/src/state/show/show_store.dart';
import 'package:muse/src/state/show/show_wire.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_audio.dart';

class _QuietMixer extends Mixer {
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

class _Feed extends ChangeNotifier implements ShowFeed {
  @override
  ShowState state = ShowState(now: DateTime(2026), a: const ShowDeck(name: 'A'), b: const ShowDeck(name: 'B'));
  final _events = StreamController<ShowEvent>.broadcast();
  @override
  Stream<ShowEvent> get events => _events.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    StylePool.heldShot = null;
    StylePool.typeNow = null;
    StylePool.shotNow.clear();
  });

  test('a favourite is kept in the document as it was', () {
    final f = ShowFave(
      id: 'a1',
      at: DateTime.utc(2026, 10, 22, 20),
      combo: const Combo(ground: 'milk', scene: 'dance-art', style: 'crt', mask: Mask.keyhole, mix: Mix.add),
      milk: 'Geiss - Reaction Diffusion',
      shot: 'dancers.fisheye',
      type3d: const TypeSpec(lines: ['HI'], motions: {TypeMotion.drift}, looks: {TypeLook.glass}, deforms: {TypeDeform.melt}),
      stars: 4,
      name: 'Glass drip',
    );
    final doc = ShowDoc.fromJson(jsonDecode(jsonEncode(ShowDoc(faves: [f]).toJson())) as Map<String, dynamic>);
    final back = doc.faves.single;
    expect(back.combo, f.combo);
    expect(back.milk, f.milk);
    expect(back.shot, f.shot);
    expect(back.type3d, f.type3d);
    expect(back.stars, 4);
    expect(back.name, 'Glass drip');
    expect(back.at.toUtc(), f.at);
    // Not rated, no name: nothing said of either.
    expect(ShowFave(id: 'b', at: DateTime(2026), combo: f.combo).toJson().keys, isNot(contains('stars')));
    expect(ShowFave.fromJson({'id': 'x', 'c': 'nonsense'}), isNull);
  });

  group('on the engine', () {
    late Booth booth;
    late ShowEngine show;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      JustAudioPlatform.instance = FakeJustAudio();
      booth = Booth(ApiClient(baseUrl: 'http://example.invalid')..token = 'x', mixer: _QuietMixer(), showStore: MemoryShowStore());
      await booth.init();
      show = booth.show;
      await show.ready();
      show.director.scenes = const [SceneMeta(id: 'type3d'), SceneMeta(id: 'dance-art')];
      show.director.kinds = const {'type3d': Figure.type3d, 'dance-art': Figure.dancers};
    });

    tearDown(() => booth.dispose());

    test('what is on kept: the 3D text narrowed to its motion, look and bends; put back on, held, whatever the rules; let go', () {
      show.setPool(show.pool.copyWith(type3d: const TypeSpec(lines: ['ONE', 'TWO'])));
      const combo = Combo(ground: 'black', scene: 'type3d', style: 'crt');
      show.play(combo);
      StylePool.typeNow = (motion: TypeMotion.orbit, look: TypeLook.mercury, bends: {TypeDeform.ripple, TypeDeform.shatter});
      final f = show.faveNow()!;
      expect(f.combo, combo);
      expect(f.milk, isNull);
      expect(f.shot, isNull);
      expect(f.type3d!.lines, ['ONE', 'TWO']);
      expect(f.type3d!.motions, {TypeMotion.orbit});
      expect(f.type3d!.looks, {TypeLook.mercury});
      expect(f.type3d!.deforms, {TypeDeform.ripple, TypeDeform.shatter});
      show.keepFave(f);
      show.putFave(f.copyWith(stars: 5));
      expect(show.faves.single.stars, 5);

      // The plan since: the scene off, let go.
      show.setPlan(show.pool.plan.withScene('type3d', muted: true));
      show.holdScene(false);
      show.playFave(show.faves.single);
      show.tick(DateTime.now());
      expect(show.combo, combo);
      expect(show.sceneHeld, isTrue);
      expect(show.faveOn?.id, f.id);
      expect(show.state.macros.type3d.motions, {TypeMotion.orbit});
      // The pool's own 3D text is untouched, and comes back on the let go.
      expect(show.pool.type3d.motions, isNot({TypeMotion.orbit}));
      show.holdScene(false);
      expect(show.faveOn, isNull);
      expect(show.macros.type3d, show.pool.type3d);
    });

    test('the dancers\' framing kept, held while the favourite is on, let go by NEXT', () {
      show.play(const Combo(ground: 'milk', scene: 'dance-art', style: 'plain'));
      StylePool.shotNow[Figure.dancers] = 'fisheye';
      final f = show.faveNow()!;
      expect(f.shot, 'dancers.fisheye');
      show.holdScene(false);
      show.playFave(f);
      expect(StylePool.heldShot, 'dancers.fisheye');
      expect(StylePool.held(Figure.dancers), 'fisheye');
      expect(StylePool.held(Figure.birds), isNull);
      show.nextScene();
      expect(StylePool.heldShot, isNull);
      expect(show.faveOn, isNull);
    });
  });

  test('a framing held goes over the wire; what the stage shows comes back', () {
    StylePool.heldShot = 'birds.low';
    final lines = <String>[];
    final wire = ShowWire(_Feed(), lines.add);
    StylePool.heldShot = null;
    final far = RemoteShowFeed();
    for (final l in lines) {
      far.arrived(l);
    }
    expect(StylePool.heldShot, 'birds.low');
    wire.close();
    far.dispose();

    // The far end says what it shows; the booth hears it.
    StylePool.shotNow[Figure.dancers] = 'close';
    StylePool.typeNow = (motion: TypeMotion.zoom, look: TypeLook.pop, bends: {TypeDeform.slice});
    final said = stageNowJson();
    StylePool.shotNow.clear();
    StylePool.typeNow = null;
    expect(heardStageNow(said), isTrue);
    expect(StylePool.shotNow[Figure.dancers], 'close');
    expect(StylePool.typeNow?.look, TypeLook.pop);
    expect(StylePool.typeNow?.bends, {TypeDeform.slice});
    expect(heardStageNow('{"t":"ping"}'), isFalse);
  });
}
