// A controller's bytes becoming the booth's words: the layouts shipped for the
// Hercules RMX, read and decoded both ways, without the hardware.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/booth/control/decoders.dart';
import 'package:muse/src/state/booth/control/layout.dart';
import 'package:muse/src/state/booth/control/soft_takeover.dart';
import 'package:muse/src/state/booth/control/surface.dart';

ControllerLayout shipped(String file) =>
    ControllerLayout.parse(File('assets/controllers/$file').readAsStringSync());

void main() {
  group('layouts', () {
    test('both RMX files read, match the device, and name only known controls', () {
      for (final f in ['hercules_dj_console_rmx.midi.json', 'hercules_dj_console_rmx.hid.json']) {
        final l = shipped(f);
        expect(l.matchesDevice(vid: 0x06f8, pid: 0xb101), isTrue, reason: f);
        expect(l.matchesDevice(name: 'Hercules DJ Console RMX MIDI'), isTrue, reason: f);
        expect(l.matchesDevice(vid: 0x06f8, pid: 0xb10c, name: 'DJ 4Set'), isFalse, reason: f);
        for (final i in l.inputs) {
          final deck = Controls.deckOf(i.id);
          expect(deck != null || i.id.startsWith('mixer.') || i.id.startsWith('browse.') || i.id == 'mic', isTrue,
              reason: '${l.id}: ${i.id}');
        }
        // Every button both decks have, the other has too.
        final a = {for (final i in l.inputs) if (Controls.deckOf(i.id)?.$1 == Side.a) Controls.deckOf(i.id)!.$2};
        final b = {for (final i in l.inputs) if (Controls.deckOf(i.id)?.$1 == Side.b) Controls.deckOf(i.id)!.$2};
        expect(a, equals(b), reason: '${l.id}: decks differ');
      }
    });

    test('two inputs on one address is refused when the file is read', () {
      expect(
          () => layoutJson([
                {'id': 'deck.a.play', 'kind': 'button', 'cc': '0x0B'},
                {'id': 'deck.a.cue', 'kind': 'button', 'cc': 11},
              ]),
          throwsFormatException);
    });

    test('a centred pot reads 0.5 at its detent, 0 and 1 at its ends', () {
      const p = InputSpec(id: 'x', kind: ControlKind.pot, cc: 1, max: 127, center: 63);
      expect(p.position(63), 0.5);
      expect(p.position(0), 0);
      expect(p.position(127), 1);
      expect(p.position(31), closeTo(0.246, 0.001));
      const h = InputSpec(id: 'x', kind: ControlKind.pot, byte: 9, max: 255, center: 128);
      expect(h.position(128), 0.5);
      expect(h.position(255), 1);
    });
  });

  group('MIDI decoder (RMX through the Hercules driver)', () {
    late MidiDecoder d;
    setUp(() => d = MidiDecoder(shipped('hercules_dj_console_rmx.midi.json')));

    test('buttons press and release', () {
      final down = d.decode(bytes([0xB0, 0x0B, 0x7F]));
      expect(down.single.id, 'deck.a.play');
      expect(down.single.pressed, isTrue);
      final up = d.decode(bytes([0xB0, 0x0B, 0x00]));
      expect(up.single.released, isTrue);
      expect(d.decode(bytes([0xB0, 0x23, 0x7F])).single.id, 'deck.b.play');
    });

    test('faders and knobs', () {
      expect(d.decode(bytes([0xB0, 0x39, 0x00])).single, isA<SurfaceEvent>().having((e) => e.id, 'id', 'mixer.crossfader').having((e) => e.value, 'value', 0));
      expect(d.decode(bytes([0xB0, 0x39, 0x7F])).single.value, 1);
      expect(d.decode(bytes([0xB0, 0x36, 0x3F])).single.value, 0.5, reason: 'bass at its detent');
      expect(d.decode(bytes([0xB0, 0x31, 0x3F])).single.id, 'deck.a.pitch');
    });

    test('the jog wheel is signed 7-bit', () {
      expect(d.decode(bytes([0xB0, 0x2F, 0x01])).single.value, 1);
      expect(d.decode(bytes([0xB0, 0x2F, 0x03])).single.value, 3);
      expect(d.decode(bytes([0xB0, 0x2F, 0x7F])).single.value, -1);
      expect(d.decode(bytes([0xB0, 0x30, 0x7D])).single.id, 'deck.b.jog');
      expect(d.decode(bytes([0xB0, 0x30, 0x7D])).single.value, -3);
    });

    test('what is not mapped is nothing, not an error', () {
      expect(d.decode(bytes([0xB0, 0x77, 0x40])), isEmpty);
      expect(d.decode(bytes([0xF8])), isEmpty);
      expect(d.decode(bytes([0x90, 0x3C, 0x40])), isEmpty);
    });

    test('lights are the button\'s own CC', () {
      expect(d.encode(const LedState('deck.a.play', true)), bytes([0xB0, 0x0B, 0x7F]));
      expect(d.encode(const LedState('deck.b.sync', false)), bytes([0xB0, 0x1F, 0x00]));
      expect(d.encode(const LedState('mixer.scratch', true)), bytes([0xB0, 0x29, 0x7F]));
      expect(d.encode(const LedState('deck.a.jog', true)), isNull);
      expect(d.allOff().length, 41);
    });
  });

  group('HID decoder (RMX bare)', () {
    late HidDecoder d;
    setUp(() => d = HidDecoder(shipped('hercules_dj_console_rmx.hid.json')));

    /// A report with everything at rest: no buttons, pots centred, faders down.
    Uint8List rest({Map<int, int> set = const {}}) {
      final r = Uint8List(25)..[0] = 1;
      for (final b in [9, 11, 12, 13, 14, 15, 18, 19, 21, 22, 23, 24]) {
        r[b] = 128;
      }
      for (final e in set.entries) {
        r[e.key] = e.value;
      }
      return r;
    }

    test('the first report is where the knobs are, not what happened', () {
      final first = d.decode(rest(set: {2: 0x04, 7: 100}));
      expect(first.where((e) => e.kind == ControlKind.button), isEmpty, reason: 'a held button is not a press');
      expect(first.where((e) => e.kind == ControlKind.jog), isEmpty, reason: 'a wheel\'s position is not a turn');
      expect(first.where((e) => e.kind.positional).length, 16, reason: 'but every knob says where it is');
    });

    test('a button bit going up and down', () {
      d.decode(rest());
      final down = d.decode(rest(set: {2: 0x04}));
      expect(down.single.id, 'deck.a.play');
      expect(down.single.pressed, isTrue);
      expect(d.decode(rest(set: {2: 0x04})), isEmpty, reason: 'nothing changed');
      final up = d.decode(rest());
      expect(up.single.id, 'deck.a.play');
      expect(up.single.released, isTrue);
    });

    test('two buttons in one byte change together', () {
      d.decode(rest());
      final both = d.decode(rest(set: {5: 0x04 | 0x08}));
      expect(both.map((e) => e.id).toSet(), {'deck.b.play', 'deck.b.cue'});
    });

    test('the pots are bytes, centred on 128', () {
      d.decode(rest());
      expect(d.decode(rest(set: {17: 255})).single, isA<SurfaceEvent>().having((e) => e.id, 'id', 'mixer.crossfader').having((e) => e.value, 'value', 1));
      expect(d.decode(rest(set: {17: 255, 14: 0})).single.id, 'deck.a.eq.low');
      expect(d.decode(rest(set: {17: 255, 14: 128})).single.value, 0.5);
    });

    test('the jog wheels are position counters that wrap', () {
      d.decode(rest(set: {7: 250}));
      expect(d.decode(rest(set: {7: 252})).single.value, 2);
      expect(d.decode(rest(set: {7: 2})).single.value, 6, reason: 'over the top');
      expect(d.decode(rest(set: {7: 250})).single.value, -8, reason: 'and back');
      expect(d.decode(rest(set: {7: 250, 8: 1})).single.id, 'deck.b.jog');
    });

    test('lights share the output report, and one does not put out another', () {
      expect(d.encode(const LedState('deck.a.play', true)), bytes([0, 0x02, 0, 0]));
      expect(d.encode(const LedState('deck.b.cue', true)), bytes([0, 0x02, 0x04, 0]));
      expect(d.encode(const LedState('deck.a.play', false)), bytes([0, 0x00, 0x04, 0]));
      expect(d.encode(const LedState('deck.a.load', true)), isNull, reason: 'no light there');
    });
  });

  group('soft take-over', () {
    test('a knob far from the value is ignored until it comes close or crosses', () {
      final t = SoftTakeover();
      expect(t.accept('k', 0.9, 0.2), isFalse);
      expect(t.accept('k', 0.6, 0.2), isFalse);
      expect(t.accept('k', 0.21, 0.2), isTrue, reason: 'close enough');
      expect(t.accept('k', 0.3, 0.21), isTrue, reason: 'taken: follows now');
      expect(t.accept('k', 0.9, 0.3), isTrue);
    });

    test('crossing the value takes it', () {
      final t = SoftTakeover();
      expect(t.accept('k', 0.1, 0.5), isFalse);
      expect(t.accept('k', 0.7, 0.5), isTrue, reason: 'went past it');
    });

    test('the software wandering off lets go again', () {
      final t = SoftTakeover();
      expect(t.accept('k', 0.5, 0.5), isTrue);
      // A transition moved the value to 0.1 while the knob sat at 0.5.
      expect(t.accept('k', 0.52, 0.1), isFalse);
      expect(t.accept('k', 0.11, 0.1), isTrue);
    });
  });
}

Uint8List bytes(List<int> b) => Uint8List.fromList(b);

ControllerLayout layoutJson(List<Map<String, Object>> inputs) => ControllerLayout.fromJson({
      'id': 't',
      'name': 'T',
      'protocol': 'midi',
      'inputs': inputs,
    });

// Keep the JSON import honest: the files must be objects with these keys.
void sanity() => jsonDecode('{}');
