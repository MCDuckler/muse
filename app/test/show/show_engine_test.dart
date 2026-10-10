// The engine on a real booth: a record on a deck is a deck in the frame, the master
// follows the fader, the palette follows the record, a hit fades; and a recording of
// it plays back as a feed.
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/deck.dart';
import 'package:muse/src/state/booth/mixer.dart';
import 'package:muse/src/state/show/show_engine.dart';
import 'package:muse/src/state/show/show_events.dart';
import 'package:muse/src/state/show/show_recorder.dart';
import 'package:muse/src/state/show/show_state.dart';

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
      'cover_color': id == 1 ? '#ff0000' : '#0000ff',
    });

/// A mixer that does nothing, on no engine.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Booth booth;
  late ShowEngine show;

  setUp(() async {
    JustAudioPlatform.instance = FakeJustAudio();
    booth = Booth(ApiClient(baseUrl: 'http://example.invalid')..token = 'x', mixer: QuietMixer());
    await booth.init();
    booth.timing.put(1, grid(500));
    booth.timing.put(2, grid(500));
    show = booth.show;
  });

  tearDown(() => booth.dispose());

  test('an empty booth is an empty frame', () {
    show.tick(DateTime(2026, 1, 1));
    expect(show.state.a.trackId, isNull);
    expect(show.state.master.name, 'A');
    expect(show.state['intensity'], 0);
  });

  test('a record on A: in the frame, with its grid and its colour', () async {
    await booth.load(booth.a, song(1));
    final said = <ShowEvent>[];
    show.events.listen(said.add);
    show.tick(DateTime(2026, 1, 1));
    final a = show.state.a;
    expect(a.trackId, 1);
    expect(a.title, 'Song 1');
    expect(a.bpm, closeTo(120, 0.01));
    expect(a.beatIndex, isNotNull);
    expect(a.coverColor, isNotNull);
    expect(said.map((e) => e.kind), contains(ShowEventKind.loaded));
    expect(show.state.flat.containsKey('master.beat.phase'), isTrue);
  });

  test('the master follows the fader, and keeps the room until clearly outfaded', () async {
    await booth.load(booth.a, song(1));
    await booth.load(booth.b, song(2));
    await booth.a.play();
    await booth.b.play();
    final t = DateTime(2026, 1, 1);
    show.tick(t);
    expect(show.state.masterName, 'A');
    await booth.setCrossfader(0.55);
    show.tick(t.add(const Duration(milliseconds: 16)));
    expect(show.state.masterName, 'A', reason: 'a hair past the middle is not a handover');
    await booth.setCrossfader(1);
    show.tick(t.add(const Duration(milliseconds: 32)));
    expect(show.state.masterName, 'B');
  });

  test('the palette eases towards the record, the hit fades', () async {
    await booth.load(booth.a, song(1));
    final t = DateTime(2026, 1, 1);
    // The first frame is the record's straight away: nothing to ease from.
    show.tick(t);
    final red = show.state.palette.primary.hue;
    expect(red < 30 || red > 330, isTrue, reason: 'hue $red');
    // A blue record on B, with the room: the palette on its way, then there.
    await booth.load(booth.b, song(2));
    await booth.b.play();
    await booth.setCrossfader(1);
    show.tick(t.add(const Duration(milliseconds: 100)));
    expect(show.state.masterName, 'B');
    final onTheWay = show.state.palette.primary.hue;
    expect(onTheWay, isNot(closeTo(red, 1)));
    expect((onTheWay - 240).abs(), greaterThan(20), reason: 'not there yet: $onTheWay');
    show.tick(t.add(const Duration(seconds: 3)));
    final settled = show.state.palette.primary.hue;
    expect((settled - 240).abs(), lessThan(20), reason: 'hue $settled');
    show.hit(at: t.add(const Duration(seconds: 3)));
    expect(show.state.macros.hit, 1);
    show.tick(t.add(const Duration(seconds: 3, milliseconds: 200)));
    expect(show.state.macros.hit, lessThan(0.6));
    show.tick(t.add(const Duration(seconds: 4)));
    expect(show.state.macros.hit, 0);
  });

  test('a frame goes to JSON and back whole', () async {
    await booth.load(booth.a, song(1));
    show.tick(DateTime(2026, 1, 1));
    final back = ShowState.fromJson(show.state.toJson());
    expect(back.a.trackId, 1);
    expect(back.a.bpm, show.state.a.bpm);
    expect(back.masterName, show.state.masterName);
    expect(back['master.bpm'], show.state['master.bpm']);
  });

  test('recorded, then played back as a feed', () async {
    await booth.load(booth.a, song(1));
    final lines = <String>[];
    final rec = ShowRecorder(show, lines.add);
    show.tick(DateTime(2026, 1, 1));
    show.hit(at: DateTime(2026, 1, 1, 0, 0, 0, 500));
    show.tick(DateTime(2026, 1, 1, 0, 0, 1));
    rec.stop();
    expect(lines.length, greaterThanOrEqualTo(3), reason: 'a header, a frame, a hit');

    final replay = ShowReplay(lines);
    expect(replay.frameCount, greaterThanOrEqualTo(1));
    final got = <ShowEvent>[];
    replay.events.listen(got.add);
    var frames = 0;
    replay.addListener(() => frames++);
    replay.advanceTo(const Duration(seconds: 5));
    expect(frames, greaterThanOrEqualTo(1));
    expect(replay.state.a.trackId, 1);
    expect(got.map((e) => e.kind), contains(ShowEventKind.hit));
  });
}
