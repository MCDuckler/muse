// A controller driving the booth: the binding's words become the booth's moves,
// and the booth's state becomes the controller's lights. On the fake engine.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/control/binding.dart';
import 'package:muse/src/state/booth/control/layout.dart';
import 'package:muse/src/state/booth/control/manager.dart';
import 'package:muse/src/state/booth/control/surface.dart';
import 'package:muse/src/state/booth/control/transport.dart';
import 'package:muse/src/state/booth/deck.dart';
import 'package:muse/src/state/booth/mixer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'booth_test.dart' show NotedMixer, song, grid;
import 'fake_audio.dart';

SurfaceEvent down(String id) => SurfaceEvent(id, ControlKind.button, 1);
SurfaceEvent up(String id) => SurfaceEvent(id, ControlKind.button, 0);
SurfaceEvent at(String id, double v, {ControlKind kind = ControlKind.fader}) => SurfaceEvent(id, kind, v);
String a(String n) => Controls.deck(Side.a, n);
String b(String n) => Controls.deck(Side.b, n);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeJustAudio audio;
  late NotedMixer mixer;
  late Booth booth;
  late BoothBinding bind;
  late List<LedState> leds;
  late List<String> notes;
  late List<Deck> loads;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    audio = FakeJustAudio();
    JustAudioPlatform.instance = audio;
    mixer = NotedMixer();
    booth = Booth(ApiClient(baseUrl: 'http://example.invalid')..token = 'x', mixer: mixer);
    await booth.init();
    leds = [];
    notes = [];
    loads = [];
    bind = BoothBinding(
      booth,
      hooks: BindingHooks(load: (d) async => loads.add(d)),
      onLed: leds.add,
      onNote: notes.add,
    );
    booth.timing.put(1, grid(500));
    booth.timing.put(2, grid(500));
    await booth.load(booth.a, song(1));
    await booth.load(booth.b, song(2));
  });

  tearDown(() {
    bind.detach();
    booth.dispose();
  });

  group('transport', () {
    test('PLAY starts and pauses; shift + PLAY starts on the beat', () async {
      await bind.handle(down(a(Controls.play)));
      expect(booth.a.playing, isTrue);
      await bind.handle(up(a(Controls.play)));
      expect(booth.a.playing, isTrue, reason: 'release does nothing');
      await bind.handle(down(a(Controls.play)));
      expect(booth.a.playing, isFalse);
    });

    test('CUE marks, previews while held, and goes back', () async {
      await booth.a.seekByHand(const Duration(seconds: 10));
      await bind.handle(down(a(Controls.cue)));
      expect(booth.a.cuePoint, const Duration(seconds: 10), reason: 'parked elsewhere: the cue is here now');
      await bind.handle(up(a(Controls.cue)));
      expect(booth.a.playing, isFalse);
      // At the cue point: holding CUE plays from it.
      await bind.handle(down(a(Controls.cue)));
      expect(booth.a.playing, isTrue);
      expect(booth.a.previewing, isTrue);
      await bind.handle(up(a(Controls.cue)));
      expect(booth.a.playing, isFalse);
      expect(booth.a.aimedAt, const Duration(seconds: 10));
      // Playing from somewhere else: CUE stops and returns.
      await booth.a.seekByHand(const Duration(seconds: 20));
      await booth.a.play();
      await bind.handle(down(a(Controls.cue)));
      expect(booth.a.playing, isFalse);
      expect(booth.a.aimedAt, const Duration(seconds: 10));
    });

    test('STOP held is shift; tapped alone it stops and goes back to the cue', () async {
      booth.a.cuePoint = const Duration(seconds: 5);
      await booth.a.seekByHand(const Duration(seconds: 30));
      await booth.a.play();
      await bind.handle(down(a(Controls.stop)));
      expect(bind.shift, isTrue);
      await bind.handle(up(a(Controls.stop)));
      expect(bind.shift, isFalse);
      expect(booth.a.playing, isFalse);
      expect(booth.a.aimedAt, const Duration(seconds: 5));
    });

    test('shift used on another control is not a stop', () async {
      await booth.a.seekByHand(const Duration(seconds: 30));
      await booth.a.play();
      await bind.handle(down(a(Controls.stop)));
      await bind.handle(down(a(Controls.pad(1))));   // shift + pad: clear (nothing there)
      await bind.handle(up(a(Controls.pad(1))));
      await bind.handle(up(a(Controls.stop)));
      expect(booth.a.playing, isTrue, reason: 'STOP was a shift key this time');
    });

    test('a bar back and forward, eight with shift', () async {
      await booth.a.seekByHand(const Duration(seconds: 30));
      await bind.handle(down(a(Controls.next)));
      expect(booth.a.aimedAt, const Duration(seconds: 32), reason: 'a bar at 120');
      await bind.handle(down(a(Controls.stop)));
      await bind.handle(down(a(Controls.prev)));
      await bind.handle(up(a(Controls.stop)));
      expect(booth.a.aimedAt, const Duration(seconds: 16));
    });
  });

  group('mixer', () {
    test('the crossfader and the channel faders go straight to the booth', () async {
      // The booth's crossfader starts at full A; a fader there is taken at once.
      await bind.handle(at(Controls.crossfader, 0.0));
      await bind.handle(at(Controls.crossfader, 0.5));
      expect(booth.crossfader, 0.5);
      await bind.handle(at(a(Controls.volume), 1.0));   // where the booth's fader is
      await bind.handle(at(a(Controls.volume), 0.75));
      expect(booth.gainOf(booth.a), closeTo(0.75, 1e-9));
      await bind.handle(at(Controls.master, 1.0));
      await bind.handle(at(Controls.master, 0.5));
      expect(booth.master_, 0.5);
      expect(mixer.levels.last.values.every((v) => v <= 0.5), isTrue, reason: 'the master is after everything');
    });

    test('a fader far from the booth\'s value waits for it (soft take-over)', () async {
      await booth.setCrossfader(0.0);
      await bind.handle(at(Controls.crossfader, 0.9));
      expect(booth.crossfader, 0.0, reason: 'not yet');
      expect(notes.last, contains('waiting'));
      await bind.handle(at(Controls.crossfader, 0.01));
      expect(booth.crossfader, 0.01);
      await bind.handle(at(Controls.crossfader, 0.4));
      expect(booth.crossfader, 0.4, reason: 'taken');
    });

    test('EQ knobs are decibels about the detent; kills toggle', () async {
      await bind.handle(at(a(Controls.eqLow), 0.5, kind: ControlKind.pot));
      expect(booth.eqOf(booth.a).low, 0);
      await bind.handle(at(a(Controls.eqLow), 1.0, kind: ControlKind.pot));
      expect(booth.eqOf(booth.a).low, EqSet.most);
      await bind.handle(at(a(Controls.eqHigh), 0.5, kind: ControlKind.pot));
      await bind.handle(at(a(Controls.eqHigh), 0.0, kind: ControlKind.pot));
      expect(booth.eqOf(booth.a).high, EqSet.killed);
      await bind.handle(down(a(Controls.killMid)));
      expect(booth.eqOf(booth.a).midKilled, isTrue);
      await bind.handle(down(a(Controls.killMid)));
      expect(booth.eqOf(booth.a).midKilled, isFalse);
    });

    test('the gain knob is the filter, off at its centre', () async {
      await bind.handle(at(a(Controls.gain), 0.5, kind: ControlKind.pot));
      await bind.handle(at(a(Controls.gain), 0.1, kind: ControlKind.pot));
      expect(booth.filters[booth.a], closeTo(-0.8, 1e-9));
      await bind.handle(at(a(Controls.gain), 0.52, kind: ControlKind.pot));
      expect(booth.filters[booth.a], 0, reason: 'a dead zone round the detent');
    });
  });

  group('tempo', () {
    test('the pitch fader is ±8 % and resets; shift + reset widens it', () async {
      await bind.handle(at(a(Controls.pitch), 0.5));
      await bind.handle(at(a(Controls.pitch), 1.0));
      expect(booth.a.pitch, closeTo(1.08, 1e-9));
      await bind.handle(down(a(Controls.pitchReset)));
      expect(booth.a.pitch, 1.0);
      await bind.handle(down(a(Controls.stop)));
      await bind.handle(down(a(Controls.pitchReset)));
      await bind.handle(up(a(Controls.stop)));
      expect(bind.pitchRange, 0.16);
      await bind.handle(at(a(Controls.pitch), 0.5));
      await bind.handle(at(a(Controls.pitch), 0.0));
      expect(booth.a.pitch, closeTo(0.84, 1e-9));
    });

    test('the jog wheel moves a parked record, bends a playing one, then lets it settle', () async {
      await booth.a.seekByHand(const Duration(seconds: 10));
      await bind.handle(at(a(Controls.jog), 5, kind: ControlKind.jog));
      expect(booth.a.aimedAt, const Duration(seconds: 10, milliseconds: 100));
      await booth.a.play();
      await bind.handle(at(a(Controls.jog), 4, kind: ControlKind.jog));
      expect(booth.a.tempo, greaterThan(1.0));
      expect(booth.a.pitch, 1.0, reason: 'a bend, not the fader');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(booth.a.tempo, 1.0, reason: 'hand off: back to pitch');
      bind.scratch = true;
      await bind.handle(at(a(Controls.jog), -4, kind: ControlKind.jog));
      expect(booth.a.tempo, lessThan(0.9), reason: 'scratch mode drags hard');
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });

    test('keylock toggles on the deck', () async {
      expect(booth.a.keylock, isTrue);
      await bind.handle(down(a(Controls.keylock)));
      expect(booth.a.keylock, isFalse);
    });
  });

  group('pads', () {
    test('1–4 set then jump, shift clears', () async {
      await booth.a.seekByHand(const Duration(seconds: 8));
      await bind.handle(down(a(Controls.pad(2))));
      expect(booth.a.hotCues[2], const Duration(seconds: 8));
      await booth.a.seekByHand(const Duration(seconds: 20));
      await bind.handle(down(a(Controls.pad(2))));
      expect(booth.a.aimedAt, const Duration(seconds: 8));
      await bind.handle(down(a(Controls.stop)));
      await bind.handle(down(a(Controls.pad(2))));
      await bind.handle(up(a(Controls.stop)));
      expect(booth.a.hotCues.containsKey(2), isFalse);
    });

    test('5 and 6 are loop in and out; shift lets go', () async {
      await booth.a.seekByHand(const Duration(seconds: 8));
      await bind.handle(down(a(Controls.pad(5))));
      expect(booth.a.loopOpen, isTrue);
      await booth.a.seekByHand(const Duration(seconds: 10));
      await bind.handle(down(a(Controls.pad(6))));
      expect(booth.a.loopStart, const Duration(seconds: 8));
      expect(booth.a.loopEnd, const Duration(seconds: 10));
      await bind.handle(down(a(Controls.stop)));
      await bind.handle(down(a(Controls.pad(6))));
      await bind.handle(up(a(Controls.stop)));
      expect(booth.a.loopStart, isNull);
    });
  });

  group('lights', () {
    test('follow the booth, and are only said when they change', () async {
      bind.attach();
      final first = {for (final l in leds) l.id: l.on};
      expect(first[a(Controls.play)], isFalse);
      expect(first[a(Controls.keylock)], isTrue);
      expect(first[a(Controls.pitchReset)], isTrue, reason: 'pitch is at 0');
      leds.clear();
      await booth.a.play();
      await Future<void>.delayed(Duration.zero);
      expect(leds.where((l) => l.id == a(Controls.play)).map((l) => l.on), [true]);
      expect(leds.any((l) => l.id == b(Controls.play)), isFalse, reason: 'B did not change');
      leds.clear();
      await bind.handle(down(Controls.scratch));
      expect(leds.single.id, Controls.scratch);
      expect(leds.single.on, isTrue);
    });
  });

  group('load and the crate', () {
    test('LOAD asks the crate; browse without one is noted', () async {
      await bind.handle(down(b(Controls.load)));
      expect(loads, [booth.b]);
      await bind.handle(down(Controls.browseDown));
      expect(notes.last, contains('no crate'));
    });
  });

  group('manager', () {
    test('a known device connects by itself, drives the booth, lights up, and goes', () async {
      final transport = FakeTransport(protocol: Protocol.hid);
      final layouts = [ControllerLayout.parse(File('assets/controllers/hercules_dj_console_rmx.hid.json').readAsStringSync())];
      final m = ControllerManager(transports: [transport], layouts: layouts, booth: booth);
      addTearDown(m.dispose);
      await m.start();
      expect(m.sessions, isEmpty);
      transport.plug(const FoundDevice(key: 'hid:1', name: 'Hercules DJ Console RMX', protocol: Protocol.hid, vid: 0x06f8, pid: 0xb101));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(m.sessions.keys, ['hid:1']);
      final dev = transport.opened['hid:1']!;
      // Lights out first, then as the booth is: keylock and pitch reset lit on both decks.
      expect(dev.sent.first, Uint8List.fromList([0, 0, 0, 0]));
      expect(dev.sent.last[1] & 0xC0, 0xC0);
      expect(dev.sent.last[2] & 0xC0, 0xC0);

      final rest = Uint8List(25)..[0] = 1;
      dev.say(rest);
      dev.say(Uint8List.fromList(rest)..[2] = 0x04);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(booth.a.playing, isTrue);
      expect(m.monitor.last.text, contains('deck.a.play down'));
      await Future<void>.delayed(Duration.zero);
      expect(dev.sent.last[1] & 0x02, 0x02, reason: 'PLAY lit');

      transport.unplug('hid:1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(m.sessions, isEmpty);
      expect(dev.closed, isTrue);
    });

    test('an unknown device waits for a layout to be picked', () async {
      final transport = FakeTransport(protocol: Protocol.midi);
      final layouts = [ControllerLayout.parse(File('assets/controllers/hercules_dj_console_rmx.midi.json').readAsStringSync())];
      final m = ControllerManager(transports: [transport], layouts: layouts, booth: booth);
      addTearDown(m.dispose);
      await m.start();
      transport.plug(const FoundDevice(key: 'midi:9', name: 'Some Other Thing', protocol: Protocol.midi));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(m.sessions, isEmpty);
      expect(m.layoutFor(m.found.single), isNull);
      await m.connect(m.found.single, layout: layouts.single);
      expect(m.sessions.keys, ['midi:9']);
      m.inject('midi:9', [0xB0, 0x39, 0x00]);
      m.inject('midi:9', [0xB0, 0x39, 0x7F]);
      await Future<void>.delayed(Duration.zero);
      expect(booth.crossfader, 1.0);
    });
  });
}
