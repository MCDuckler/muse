// The board beside the decks: that it comes back as it was kept, that a press does
// what the pad's mode says, that a quantised pad waits for the master's beat, that a
// ducking pad holds the decks down while it sounds, and that the desk's keys reach it.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/booth/board/board_store.dart';
import 'package:muse/src/state/booth/board/pad_spec.dart';
import 'package:muse/src/state/booth/board/sampler.dart';
import 'package:muse/src/state/booth/board/samples.dart';
import 'package:muse/src/state/booth/board/soundboard.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/deck.dart';
import 'package:muse/src/state/booth/mixer.dart';

import 'fake_audio.dart';

TrackTiming grid(int ms) => TrackTiming(
      durationMs: 60000,
      bpm: 60000 / ms,
      beats: [for (var t = 0; t < 60000; t += ms) t],
      barStartsOn: 0,
    );

Track song(int id) => Track.fromJson({
      'id': id,
      'title': 'Song $id',
      'artists': ['Someone'],
      'duration_ms': 60000,
      'state': 'ready',
      'stream_url': '/tracks/$id/stream',
      'source': 'youtube',
    });

/// A mixer that writes down the levels it is told.
class NotedMixer extends Mixer {
  final levels = <({double a, double b, Duration over})>[];
  @override
  bool get canKill => true;
  @override
  bool get canFilter => false;
  @override
  Future<void> setLevels(Map<Deck, double> levels, {Duration over = Duration.zero}) async {
    final e = levels.entries.toList();
    this.levels.add((a: e[0].value, b: e[1].value, over: over));
  }

  @override
  void expecting(String deck) {}
  @override
  Future<void> setEq(Deck deck, EqSet eq) async {}
  @override
  Future<void> setFilter(Deck deck, double value) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('com.ryanheise.audio_session'), (c) async => null);

  late FakeJustAudio engine;
  late Booth booth;
  late MemoryBoardStore store;
  late NotedMixer mixer;

  setUp(() async {
    engine = FakeJustAudio();
    JustAudioPlatform.instance = engine;
    store = MemoryBoardStore();
    mixer = NotedMixer();
    booth = Booth(
      ApiClient(baseUrl: 'http://example.invalid')..token = 'x',
      mixer: mixer,
      board: (b) => Soundboard(
        b,
        store: store,
        sampler: Sampler(
          library: SampleLibrary(sink: (Uint8List wav, String key) async => '/sounds/$key.wav'),
          playerVolume: b.mixer.playerVolume,
        ),
      ),
    );
    await booth.init();
  });

  tearDown(() => booth.dispose());

  /// The players the decks made, so the board's can be told apart.
  Set<String> deckPlayers() => engine.players.keys.toSet();

  /// The board's player with [sound] in it — the one playing, where two have it.
  FakeAudioPlayer boardPlayer(Set<String> decks, String sound) {
    final with_ = engine.players.entries
        .where((e) => !decks.contains(e.key) && e.value.sources.any((s) => s.contains(sound)))
        .map((e) => e.value)
        .toList();
    return with_.firstWhere((p) => p.playing, orElse: () => with_.first);
  }

  /// play() is let go of, not waited for (it completes when the sound is over).
  Future<void> sounding() => Future<void>.delayed(const Duration(milliseconds: 20));

  test('a first board is the kit across the first row, and loading warms it', () async {
    final decks = deckPlayers();
    await booth.board.load();
    final b = booth.board;
    expect(b.doc.banks.length, 4);
    expect(b.pad(0, 0)!.sampleId, SampleKit.impact);
    expect(b.pad(0, 4)!.mode, PadMode.hold);
    expect(b.pad(1, 0), isNull);
    expect(engine.players.length - decks.length, 5, reason: 'five pads on show, five players ready');
    expect(b.sampler.voices.keys, unorderedEquals(['A:1', 'A:2', 'A:3', 'A:4', 'A:5']));
  });

  test('the board comes back as it was kept, and a change is kept a moment later', () async {
    final kept = BoardDoc.empty();
    kept.banks[2].pads[7] = const PadSpec(sampleId: SampleKit.impact, name: 'HIT', colour: PadColour.orange);
    kept.level = 0.4;
    store.kept = kept;
    await booth.board.load();
    final b = booth.board;
    expect(b.pad(2, 7)!.name, 'HIT');
    expect(b.doc.level, 0.4);
    expect(b.pad(0, 0), isNull, reason: 'the kept board, not the starter');
    await b.setLevel(0.6);
    expect(store.saves, 0, reason: 'not yet: a fader moving is not ten saves a second');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(store.saves, 1);
    expect(store.kept!.level, 0.6);
  });

  test('a one-shot press fires the pad at the law\'s level; an empty pad is nothing', () async {
    final decks = deckPlayers();
    await booth.board.load();
    final b = booth.board;
    await b.setLevel(0.5);
    await booth.setMaster(0.8);
    await b.press(0, 0);
    await sounding();
    final p = boardPlayer(decks, 'impact');
    expect(p.playing, isTrue);
    expect(p.volume, closeTo(1.0 * 0.5 * 0.8, 1e-9));
    expect(b.stateOf(0, 0).sounding, isTrue);
    expect(b.anySounding, isTrue);
    expect(b.lastFired!.name, 'IMPACT');
    await b.press(1, 3);
    expect(b.stateOf(1, 3).sounding, isFalse);
    p.reachEnd();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(b.stateOf(0, 0).sounding, isFalse);
    expect(b.anySounding, isFalse);
  });

  test('a toggle pressed twice is on then off; a hold is on while held', () async {
    final decks = deckPlayers();
    await booth.board.load();
    final b = booth.board;
    // RISER is a toggle that waits for the bar — with nothing playing, it goes now.
    await b.press(0, 1);
    expect(b.stateOf(0, 1).sounding, isTrue);
    await b.press(0, 1);
    expect(b.stateOf(0, 1).sounding, isFalse);
    await b.press(0, 4);
    await sounding();
    expect(b.stateOf(0, 4).sounding, isTrue);
    expect(b.stateOf(0, 4).held, isTrue);
    await b.release(0, 4);
    expect(b.stateOf(0, 4).sounding, isFalse);
    expect(boardPlayer(decks, 'hydrant').playing, isFalse);
  });

  test('a quantised pad waits for the master\'s beat, and a second press calls it off', () async {
    await booth.board.load();
    final b = booth.board;
    await b.setPad(0, 8, const PadSpec(sampleId: SampleKit.impact, name: 'ON THE BEAT', quantise: Quantise.beat));
    await booth.a.load(song(1), timing: grid(500));
    await booth.a.play();
    // Parked 100 ms before a beat: the pad should go in about 100 ms.
    booth.a.anchor(const Duration(milliseconds: 10400), DateTime.now());
    await b.press(0, 8);
    final s = b.stateOf(0, 8);
    expect(s.waiting, isTrue);
    expect(s.sounding, isFalse);
    final wait = s.waitingUntil!.difference(DateTime.now()).inMilliseconds;
    expect(wait, inInclusiveRange(40, 110));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(b.stateOf(0, 8).sounding, isTrue);
    expect(b.stateOf(0, 8).waiting, isFalse);

    // A bar: four beats from 10 s is 12 s, 1.6 s away — pressed again, it never goes.
    await b.setPad(0, 9, const PadSpec(sampleId: SampleKit.sweepUp, name: 'ON THE BAR', quantise: Quantise.bar));
    booth.a.anchor(const Duration(milliseconds: 10400), DateTime.now());
    await b.press(0, 9);
    expect(b.stateOf(0, 9).waiting, isTrue);
    expect(b.stateOf(0, 9).waitingUntil!.difference(DateTime.now()).inMilliseconds, inInclusiveRange(1500, 1620));
    await b.press(0, 9);
    expect(b.stateOf(0, 9).waiting, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(b.stateOf(0, 9).sounding, isFalse);
  });

  test('a ducking pad holds the decks half way down while it sounds, then lets them up slowly', () async {
    final decks = deckPlayers();
    await booth.board.load();
    final b = booth.board;
    await b.setPad(0, 8, const PadSpec(sampleId: SampleKit.impact, name: 'VOICE', duck: 1.0));
    mixer.levels.clear();
    await b.press(0, 8);
    await sounding();
    expect(booth.duck_, 0.5);
    expect(mixer.levels.last.over, const Duration(milliseconds: 20), reason: 'down quickly');
    expect(booth.levels.a, lessThanOrEqualTo(0.5));
    boardPlayer(decks, 'impact').reachEnd();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(booth.duck_, 1.0);
    expect(mixer.levels.last.over, const Duration(milliseconds: 250), reason: 'up slowly');
  });

  test('a bank turned to is warmed; the one left keeps only what still sounds', () async {
    final decks = deckPlayers();
    await booth.board.load();
    final b = booth.board;
    await b.setPad(1, 0, const PadSpec(sampleId: SampleKit.sweepDown, name: 'B1'));
    await b.press(0, 0);
    await sounding();
    await b.showBank(1);
    expect(b.bank, 1);
    expect(b.sampler.voices.keys, unorderedEquals(['A:1', 'B:1']), reason: 'A:1 sounds on; the rest of A let go');
    boardPlayer(decks, 'impact').reachEnd();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await b.stepBank(-1);
    expect(b.bank, 0);
    expect(b.sampler.voices.keys, unorderedEquals(['A:1', 'A:2', 'A:3', 'A:4', 'A:5']));
    await b.stepBank(-1);
    expect(b.bank, 3, reason: 'round the end');
  });

  test('a pinned row stays warm whichever bank is on show', () async {
    await booth.board.load();
    final b = booth.board;
    await b.setStrip(const StripSpec(bank: 0, row: 0));
    await b.showBank(2);
    expect(b.sampler.voices.keys, unorderedEquals(['A:1', 'A:2', 'A:3', 'A:4']),
        reason: 'the first row of A, pinned; A:5 is the second row');
  });

  test('the desk\'s keys: F-keys and the number pad fire pads, shift is the lower rows, repeats are swallowed',
      () async {
    await booth.board.load();
    final b = booth.board;
    await b.setPad(0, 8, const PadSpec(sampleId: SampleKit.sweepDown, name: 'NINE'));
    KeyEvent down(LogicalKeyboardKey k) =>
        KeyDownEvent(physicalKey: PhysicalKeyboardKey.keyA, logicalKey: k, timeStamp: Duration.zero);
    KeyEvent up(LogicalKeyboardKey k) =>
        KeyUpEvent(physicalKey: PhysicalKeyboardKey.keyA, logicalKey: k, timeStamp: Duration.zero);
    KeyEvent repeat(LogicalKeyboardKey k) =>
        KeyRepeatEvent(physicalKey: PhysicalKeyboardKey.keyA, logicalKey: k, timeStamp: Duration.zero);

    expect(b.keyEvent(down(LogicalKeyboardKey.f1), typing: false, shift: false), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(b.stateOf(0, 0).sounding, isTrue);
    expect(b.keyEvent(repeat(LogicalKeyboardKey.f1), typing: false, shift: false), isTrue);
    expect(b.keyEvent(down(LogicalKeyboardKey.f1), typing: false, shift: true), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(b.stateOf(0, 8).sounding, isTrue, reason: 'shift: the ninth pad');

    // A hold on F5, let go.
    expect(b.keyEvent(down(LogicalKeyboardKey.f5), typing: false, shift: false), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(b.stateOf(0, 4).sounding, isTrue);
    expect(b.keyEvent(up(LogicalKeyboardKey.f5), typing: false, shift: false), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(b.stateOf(0, 4).sounding, isFalse);

    // The number pad, and its zero.
    expect(b.keyEvent(down(LogicalKeyboardKey.numpad3), typing: true, shift: false), isTrue,
        reason: 'a pad key is nobody\'s text key');
    await Future<void>.delayed(Duration.zero);
    expect(b.stateOf(0, 2).sounding, isTrue);
    expect(b.keyEvent(down(LogicalKeyboardKey.numpad0), typing: false, shift: false), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(b.anySounding, isFalse);

    // The bank keys: not while typing.
    expect(b.keyEvent(down(LogicalKeyboardKey.period), typing: true, shift: false), isFalse);
    expect(b.bank, 0);
    expect(b.keyEvent(down(LogicalKeyboardKey.period), typing: false, shift: false), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(b.bank, 1);
    expect(b.keyEvent(down(LogicalKeyboardKey.keyQ), typing: false, shift: false), isFalse,
        reason: 'a deck\'s key is the deck\'s');
  });

  test('swapping two pads moves their sounds with them', () async {
    await booth.board.load();
    final b = booth.board;
    await b.swap((0, 0), (1, 5));
    expect(b.pad(0, 0), isNull);
    expect(b.pad(1, 5)!.name, 'IMPACT');
    expect(b.sampler.voices.containsKey('A:1'), isFalse);
    await b.showBank(1);
    expect(b.sampler.voices.keys, ['B:6']);
  });
}
