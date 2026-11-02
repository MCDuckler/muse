// A stage fed by the WetOwl Desk: the Desk's frames are decks in the show (their beats
// off the house's timing, their sound the Desk's engine's), carried forward between
// frames, and its hands reach the show the stage directs.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/show/desk_show_source.dart';
import 'package:muse/src/state/show/milk_feed.dart';
import 'package:muse/src/state/show/show_engine.dart';
import 'package:muse/src/state/show/show_store.dart';

TrackTiming grid(int ms) => TrackTiming(
      durationMs: 60000,
      bpm: 60000 / ms,
      beats: [for (var t = 0; t < 60000; t += ms) t],
      downbeats: [for (var t = 0; t < 60000; t += 4 * ms) t],
      energy: [for (var i = 0; i < 29; i++) 128],
    );

String frame({double positionMs = 1250, bool playing = true, double kick = 0.9, double level = 1}) => jsonEncode({
      't': 'desk',
      'd': {
        'a': {
          'trackId': 1,
          'title': 'Song 1',
          'artist': 'Someone',
          'playing': playing,
          'positionMs': positionMs,
          'rate': 1.0,
          'level': level,
          'eq': {'low': 0, 'mid': 0, 'high': 0},
          'filter': 0,
          'looping': false,
          'heard': {'sub': 0.5, 'low': 0.6, 'mid': 0.4, 'high': 0.3, 'air': 0.2, 'kick': kick, 'snare': 0, 'hat': 0.1, 'onset': kick},
        },
        'b': {'playing': false, 'positionMs': 0, 'rate': 1.0, 'level': 0},
        'heard': {
          'master': {'sub': 0.5, 'low': 0.6, 'mid': 0.4, 'high': 0.3, 'air': 0.2, 'kick': kick, 'snare': 0, 'hat': 0.1, 'onset': kick},
          'spectrum': [for (var i = 0; i < 32; i++) i / 32],
        },
        'mix': {'on': true, 'kind': 'blend', 'from': 'A', 'to': 'B', 'bars': 16, 'k': 0.25},
      },
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DeskShowSource source;
  late ShowEngine show;

  setUp(() {
    source = DeskShowSource(ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
    source.timing.put(1, grid(500));
    show = ShowEngine.fed(source, store: MemoryShowStore());
  });

  tearDown(() => show.dispose());

  test('nothing from the Desk yet: an empty frame', () {
    show.tick(DateTime(2026, 1, 1));
    expect(show.state.a.trackId, isNull);
    expect(source.heard, isFalse);
  });

  test("a Desk frame: its deck on the house's beats, its engine's sound, its mix", () {
    expect(deskSaid(frame(), source, show), isTrue);
    show.tick(DateTime(2026, 1, 1));
    final a = show.state.a;
    expect(a.playing, isTrue);
    expect(a.bpm, closeTo(120, 0.01));
    expect(a.beatIndex, 2, reason: '1250 ms on a 500 ms grid');
    expect(a.beatPhase, closeTo(0.5, 0.01));
    expect(a.audio.kick, closeTo(0.9, 1e-6), reason: "the Desk's engine heard it");
    expect(show.state.audio.kick, closeTo(0.9, 1e-6));
    expect(show.state.flat['live.on'], 1);
    expect(show.state.flat['spec.31'], closeTo(31 / 32, 1e-6));
    expect(show.state.mix.on, isTrue);
    expect(show.state.mix.k, 0.25);
    expect(show.state.masterName, 'A');
  });

  test('carried forward between frames, and held once the Desk is quiet', () {
    deskSaid(frame(), source, show);
    final t = DateTime.now();
    show.tick(t.add(const Duration(milliseconds: 100)));
    expect(show.state.a.position.inMilliseconds, closeTo(1350, 25));
    show.tick(t.add(const Duration(seconds: 2)));
    expect(show.state.a.position.inMilliseconds, closeTo(1500, 25), reason: 'a quarter second at most');
  });

  test('a kick in a frame the stage never drew is still seen', () {
    deskSaid(frame(kick: 0.9), source, show);
    deskSaid(frame(positionMs: 1266, kick: 0.1), source, show);
    show.tick(DateTime(2026, 1, 1));
    expect(show.state.audio.kick, closeTo(0.9, 1e-6));
    expect(show.state.a.audio.kick, closeTo(0.9, 1e-6));
    expect(show.state.a.position.inMilliseconds, 1266, reason: 'the place is the newest');
    deskSaid(frame(positionMs: 1283, kick: 0.1), source, show);
    show.tick(DateTime(2026, 1, 1, 0, 0, 0, 16));
    expect(show.state.audio.kick, closeTo(0.1, 1e-6), reason: 'read once, then gone');
  });

  test("the Desk's hands: a hit, the blackout, the scene held", () {
    deskSaid(frame(), source, show);
    show.tick(DateTime(2026, 1, 1));
    expect(deskSaid('{"t":"hands","do":"hit"}', source, show), isTrue);
    expect(show.macros.hit, 1);
    deskSaid('{"t":"hands","do":"blackout","on":true}', source, show);
    expect(show.macros.blackout, isTrue);
    deskSaid('{"t":"hands","do":"blackout","on":false}', source, show);
    expect(show.macros.blackout, isFalse);
    deskSaid('{"t":"hands","do":"hold","on":true}', source, show);
    expect(show.sceneHeld, isTrue);
    expect(jsonDecode(deskShownJson(show))['held'], isTrue);
  });

  test("a booth's lines are not the Desk's", () {
    expect(deskSaid('{"t":"state","s":{}}', source, show), isFalse);
    expect(deskSaid('{"t":"ping"}', source, show), isFalse);
  });
  test("the Desk's house: its sign-in read from the hello, the stage's api on it", () {
    expect(deskHouse('{"t":"hello","v":1,"from":"desk"}'), isNull);
    final h = deskHouse('{"t":"hello","v":1,"from":"desk","house":{"server":"https://desk.house/","token":"tk"}}');
    expect(h?.server, 'https://desk.house');
    expect(h?.token, 'tk');
    expect(deskSaid('{"t":"hello","v":1,"from":"desk","house":{"server":"https://other","token":"t2"}}', source, show), isTrue);
    expect(source.api.baseUrl, 'https://other');
    expect(source.api.token, 't2');
  });

  test("MilkDrop hears the Desk's master: its samples, in order, once each", () {
    Uint8List pcm(List<int> xs) {
      final b = ByteData(8 + xs.length * 2);
      for (final (i, c) in 'PCM1'.codeUnits.indexed) {
        b.setUint8(i, c);
      }
      b.setUint32(4, 48000, Endian.little);
      for (final (i, x) in xs.indexed) {
        b.setInt16(8 + i * 2, x, Endian.little);
      }
      return b.buffer.asUint8List();
    }

    final heard = MilkFeed.shared.pcm.heard!;
    expect(heard(), isNull, reason: 'no sound from the Desk yet: the records are read instead');
    expect(source.pcmArrived(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9])), isFalse);
    expect(source.pcmArrived(pcm([1, -2, 3])), isTrue);
    expect(source.pcmArrived(pcm([32767, -32768])), isTrue);
    expect(heard(), [1, -2, 3, 32767, -32768]);
    expect(heard(), isEmpty, reason: 'between two frames: nothing new, but not the records either');
  });
}
