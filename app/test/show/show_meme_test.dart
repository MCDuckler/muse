// The Siebenschläfer edit's clock: the mood read off the record, the length of a cut,
// and the cut itself — the same picture for the same record and cut, a roll that
// flickers between two, the drop's first beats lasered.
import 'dart:ui' show PictureRecorder;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_state.dart';
import 'package:muse/src/ui/show/show_meme.dart';
import 'package:muse/src/ui/show/show_meme_bits.dart';
import 'package:muse/src/ui/show/show_meme_type.dart';

MemePhoto photo(String id, String set) =>
    MemePhoto(id: id, file: 'photos/$id.webp', set: set, w: 1280, h: 853, face: const Offset(0.5, 0.5), faceR: 0.2, eyes: const [Offset(0.45, 0.45), Offset(0.55, 0.45)]);

final bank = MemeBank.forTest(
  [
    for (var i = 0; i < 4; i++) photo('s$i', 'sleep'),
    for (var i = 0; i < 4; i++) photo('w$i', 'wake'),
    for (var i = 0; i < 8; i++) photo('t$i', 'stare'),
    for (var i = 0; i < 6; i++) photo('c$i', 'chaos'),
  ],
  stickers: [
    for (var i = 0; i < 6; i++) MemeSticker(id: 'k$i', file: 'stickers/k$i.webp', set: i == 0 ? 'sleep' : 'awake', w: 300, h: 200, peek: i == 1),
  ],
  captions: {
    'stamps': ['GOATED'],
    'bubbles': ['nein.'],
    'errors': ['a|b'],
    'news': ['Siebenschläfer wach'],
  },
);

ShowDeck deck({
  bool playing = true,
  String? section,
  bool breakdown = false,
  double buildK = 0,
  double? away,
  double energy = 0.5,
  int beatInBar = 0,
  int barIndex = 0,
}) =>
    ShowDeck(
      name: 'a',
      trackId: 7,
      playing: playing,
      bpm: 128,
      beatIndex: barIndex * 4 + beatInBar,
      beatInBar: beatInBar,
      barIndex: barIndex,
      section: section,
      breakdown: breakdown,
      buildK: buildK,
      dropBeatsAway: away,
      energy: energy,
    );

void main() {
  group('the mood', () {
    test('a paused deck and a breakdown sleep', () {
      expect(MemeClock.mood(deck(playing: false, section: 'drop')), MemeMood.sleep);
      expect(MemeClock.mood(deck(section: 'breakdown', breakdown: true)), MemeMood.sleep);
      expect(MemeClock.mood(deck(section: 'intro', energy: 0.2)), MemeMood.sleep);
    });

    test('a drop ahead wakes it, even in the breakdown', () {
      expect(MemeClock.mood(deck(section: 'breakdown', breakdown: true, away: 12)), MemeMood.wake);
      expect(MemeClock.mood(deck(section: 'build')), MemeMood.wake);
      expect(MemeClock.mood(deck(section: 'breakdown', breakdown: true, away: 40)), MemeMood.sleep);
    });

    test('the drop rages, and for sixteen bars after it', () {
      expect(MemeClock.mood(deck(section: 'drop')), MemeMood.rage);
      expect(MemeClock.mood(deck(section: 'inst', energy: 0.9), sinceDrop: 10), MemeMood.rage);
      expect(MemeClock.mood(deck(section: 'inst', energy: 0.9), sinceDrop: 70), MemeMood.vibe);
    });

    test('a loud stretch that is not a drop is a vibe', () {
      expect(MemeClock.mood(deck(section: 'inst', energy: 0.9, away: 100)), MemeMood.vibe);
      expect(MemeClock.mood(deck(section: 'verse', energy: 0.5)), MemeMood.vibe);
    });

    test('the rage cools by phrases after its first eight bars', () {
      expect(MemeClock.heat(deck(barIndex: 9), sinceDrop: 4), 1);
      final a = MemeClock.heat(deck(barIndex: 40), sinceDrop: 200);
      final b = MemeClock.heat(deck(barIndex: 48), sinceDrop: 232);
      expect({a, b}, {0.55, 1.0});
    });
  });

  group('the cuts', () {
    test('a build rolls faster as the drop nears', () {
      final lens = [for (final away in [20.0, 12.0, 6.0, 3.0, 1.5]) MemeClock.cutBeats(MemeMood.wake, deck(away: away))];
      expect(lens, [4, 2, 1, 0.5, 0.25]);
    });

    test('a sleeper is cut every two bars, the rage on the beat with a roll every fourth bar', () {
      expect(MemeClock.cutBeats(MemeMood.sleep, deck()), 8);
      expect(MemeClock.cutBeats(MemeMood.rage, deck(barIndex: 2, beatInBar: 3)), 1);
      expect(MemeClock.cutBeats(MemeMood.rage, deck(barIndex: 3, beatInBar: 3)), 0.5);
    });

    test('the same record and cut give the same picture, and the next cut another', () {
      final m = deck(section: 'drop');
      for (var n = 100; n < 140; n++) {
        final a = MemeClock.cut(bank, MemeMood.rage, n, 1, 7, m);
        final b = MemeClock.cut(bank, MemeMood.rage, n, 1, 7, m);
        expect(a.photo.id, b.photo.id);
        expect(a.flip, b.flip);
        expect(a.tilt, b.tilt);
        expect(MemeClock.cut(bank, MemeMood.rage, n + 1, 1, 7, m).photo.id, isNot(a.photo.id));
      }
    });

    test('a sleeper is always asleep; a rage never is', () {
      for (var n = 0; n < 50; n++) {
        expect(MemeClock.cut(bank, MemeMood.sleep, n, 8, 3, deck()).photo.set, 'sleep');
        expect(MemeClock.cut(bank, MemeMood.rage, n, 1, 3, deck(section: 'drop')).photo.set, isNot('sleep'));
      }
    });

    test('a roll flickers between two pictures within a beat', () {
      final m = deck(away: 1.5);
      final ids = {for (var n = 400; n < 404; n++) MemeClock.cut(bank, MemeMood.wake, n, 0.25, 9, m).photo.id};
      expect(ids.length, 2);
    });

    test('the first beats after a drop are one picture each, with laser eyes', () {
      final m = deck(section: 'drop');
      for (var n = 0; n < 4; n++) {
        final c = MemeClock.cut(bank, MemeMood.rage, n, 1, 5, m, sinceDrop: n.toDouble());
        expect(c.grid, 1);
        expect(c.laser, isTrue);
        expect(c.symmetry, isFalse);
      }
    });
  });

  group('the styles and the bits', () {
    test('the breakdowns get all three looks across records, about half the trail camera', () {
      final skins = [for (var id = 1; id < 400; id++) MemeClock.sleepSkin(id)];
      expect(skins.toSet(), {0, 1, 2});
      final cam = skins.where((k) => k == 0).length / skins.length;
      expect(cam, inInclusiveRange(0.35, 0.65));
    });

    test('a record gets one style, the same every time, and not all the same', () {
      final styles = {for (var id = 1; id < 200; id++) MemeClock.style(id)};
      expect(styles.length, MemeStyle.values.length);
      expect(MemeClock.style(24289), MemeClock.style(24289));
    });

    MemeFrame frame(MemeMood mood, {double hot = 1, double busy = 0.5}) => MemeFrame(
          bank: bank,
          type: MemeType(),
          deck: deck(section: mood == MemeMood.rage ? 'drop' : 'inst'),
          beats: 100,
          spb: 0.5,
          t: 50,
          w: 640,
          h: 360,
          mood: mood,
          look: MemeLook.of(MemeStyle.fried),
          kick: 0, snare: 0, top: 0, low: 0, mid: 0, high: 0, beatDecay: 0, downbeat: 0, barSaw: 0,
          busy: busy, hot: hot, hue: 0.3, salt: 7, shake: Offset.zero, face: const Offset(0.5, 0.5),
          newBeat: true, snareEdge: false, kickEdge: false,
        );

    test('every bit can be made from the bank, and knows whether it takes over', () {
      final f = frame(MemeMood.vibe);
      const takeovers = {'sunburst', 'crowd', 'nobody', 'brain', 'top7', 'screensaver', 'wall', 'polaroids', 'parallax', 'kaleido', 'strips', 'spotlight', 'film', 'rings', 'duotone', 'night', 'documentary', 'loupe', 'booth', 'flip'};
      const overlays = {'warning', 'news', 'errors', 'stamp', 'bubble', 'cursor', 'pip', 'dvd', 'spectrum'};
      for (final kind in takeovers.union(overlays)) {
        final bit = MemeBitPicker.make(kind, f, 100, 3);
        expect(bit, isNotNull, reason: kind);
        expect(bit!.kind, kind);
        expect(bit.takeover, takeovers.contains(kind), reason: kind);
        expect(bit.over(f), isFalse);
        bit.dispose();
      }
      // No clip, no engravings in this bank: those two have nothing to show.
      expect(MemeBitPicker.make('clip', f, 100, 3), isNull);
      expect(MemeBitPicker.make('history', f, 100, 3), isNull);
    });

    test('the pick is the same for the same dice, and a sleeper only gets a calm one', () {
      final v = frame(MemeMood.vibe);
      for (var seed = 0; seed < 30; seed++) {
        final a = MemeBitPicker.pick(v, 100, seed, takeoverOk: true, overlayOk: true);
        final b = MemeBitPicker.pick(v, 100, seed, takeoverOk: true, overlayOk: true);
        expect(a?.kind, b?.kind);
        a?.dispose();
        b?.dispose();
      }
      // Asleep, only the calm looks: the night sky, the screensaver, the spotlight, polaroids, a film.
      final s = frame(MemeMood.sleep);
      for (var seed = 0; seed < 30; seed++) {
        final bit = MemeBitPicker.pick(s, 100, seed, takeoverOk: true, overlayOk: true);
        expect({'night', 'screensaver', 'spotlight', 'polaroids', 'film', 'bubble'}, contains(bit?.kind));
        bit?.dispose();
      }
      expect(MemeBitPicker.pick(frame(MemeMood.wake), 100, 1, takeoverOk: true, overlayOk: true), isNull);
    });

    test('a bit runs its bars and is over after them; the same kind is not picked twice running', () {
      final f = frame(MemeMood.rage);
      final bit = MemeBitPicker.make('crowd', f, 100, 1)!;
      expect(bit.k(f), 0);
      expect(bit.over(f), isFalse);
      final later = frame(MemeMood.rage);
      expect(bit.over(MemeFrame(
        bank: later.bank, type: later.type, deck: later.deck, beats: 117, spb: 0.5, t: 60, w: 640, h: 360, mood: later.mood, look: later.look,
        kick: 0, snare: 0, top: 0, low: 0, mid: 0, high: 0, beatDecay: 0, downbeat: 0, barSaw: 0, busy: 0.5, hot: 1, hue: 0, salt: 7,
        shake: Offset.zero, face: const Offset(0.5, 0.5), newBeat: false, snareEdge: false, kickEdge: false,
      )), isTrue);
      for (var seed = 0; seed < 40; seed++) {
        final pick = MemeBitPicker.pick(f, 100, seed, takeoverOk: true, overlayOk: false, notAgain: {'sunburst'});
        expect(pick?.kind, isNot('sunburst'));
        pick?.dispose();
      }
    });
  });

  test('a bold word survives the text cache clearing itself out between its stroke and its face', () {
    // The stroke is the 501st painter, the face the one that finds the cache full:
    // disposing everything there left the stroke dead in the hand that was about to
    // paint it ("text geometry was not yet calculated", on a stage, mid-set).
    final type = MemeType();
    for (var i = 0; i < 500; i++) {
      type.text('k$i', () => TextSpan(text: '$i'));
    }
    final word = type.bold('LÄDT', 40, Colors.white);
    final canvas = Canvas(PictureRecorder());
    type.paintBold(canvas, word, const Offset(100, 100));
    type.dispose();
  });
}
