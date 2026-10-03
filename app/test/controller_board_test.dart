// The board from a controller's side: the remote decoder's words become presses
// on the booth's board through the one binding, and the pads light back.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/booth/board/board_store.dart';
import 'package:muse/src/state/booth/board/link_wire.dart';
import 'package:muse/src/state/booth/board/pad_spec.dart';
import 'package:muse/src/state/booth/board/sampler.dart';
import 'package:muse/src/state/booth/board/samples.dart';
import 'package:muse/src/state/booth/board/soundboard.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/control/binding.dart';
import 'package:muse/src/state/booth/control/decoders.dart';
import 'package:muse/src/state/booth/control/layout.dart';
import 'package:muse/src/state/booth/control/surface.dart';

import 'fake_audio.dart';
import 'soundboard_test.dart' show NotedMixer;

Uint8List line(Map<String, dynamic> m) => Uint8List.fromList(utf8.encode(jsonEncode(m)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('com.ryanheise.audio_session'), (c) async => null);

  late Booth booth;

  setUp(() async {
    JustAudioPlatform.instance = FakeJustAudio();
    booth = Booth(
      ApiClient(baseUrl: 'http://example.invalid')..token = 'x',
      mixer: NotedMixer(),
      board: (b) => Soundboard(
        b,
        store: MemoryBoardStore(),
        sampler: Sampler(
          library: SampleLibrary(sink: (Uint8List wav, String key) async => '/sounds/$key.wav'),
          playerVolume: b.mixer.playerVolume,
        ),
      ),
    );
    await booth.init();
    await booth.board.load();
  });

  tearDown(() => booth.dispose());

  test('the remote decoder speaks the board\'s words', () {
    final d = RemoteDecoder(ControllerLayout.remote);
    final down = d.decode(line({'t': 'press', 'bank': 1, 'pad': 2, 'down': true}));
    expect(down.map((e) => e.id), ['board.bank.2', 'board.pad.3']);
    expect(down.last.pressed, isTrue);
    final up = d.decode(line({'t': 'press', 'pad': 2, 'down': false}));
    expect(up.single.id, 'board.pad.3');
    expect(up.single.pressed, isFalse);
    expect(d.decode(line({'t': 'stop'})).single.id, Controls.boardStop);
    final level = d.decode(line({'t': 'level', 'v': 0.4})).single;
    expect(level.id, Controls.boardLevel);
    expect(level.kind, ControlKind.fader);
    expect(level.value, 0.4);
    expect(d.decode(line({'t': 'ping', 'n': 1})), isEmpty);
    expect(d.decode(Uint8List.fromList([1, 2, 3])), isEmpty);
    expect(utf8.decode(d.encode(const LedState('board.pad.3', true))!), '{"t":"lit","id":"board.pad.3","on":true}');
  });

  test('presses reach the board through the binding, and its pads light back', () async {
    final lit = <String, bool>{};
    final binding = BoothBinding(booth, onLed: (l) => lit[l.id] = l.on);
    binding.attach();
    expect(lit['board.pad.1'], isFalse);
    expect(lit['board.stop'], isFalse);

    await binding.handle(SurfaceEvent(Controls.boardPad(1), ControlKind.button, 1));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(booth.board.stateOf(0, 0).sounding, isTrue);
    expect(lit['board.pad.1'], isTrue);
    expect(lit['board.stop'], isTrue);

    // A hold: pad 5 is the hydrant. Down, then up.
    await binding.handle(SurfaceEvent(Controls.boardPad(5), ControlKind.button, 1));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(booth.board.stateOf(0, 4).held, isTrue);
    await binding.handle(SurfaceEvent(Controls.boardPad(5), ControlKind.button, 0));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(booth.board.stateOf(0, 4).sounding, isFalse);

    await binding.handle(SurfaceEvent(Controls.boardBank(2), ControlKind.button, 1));
    expect(booth.board.bank, 1);
    await binding.handle(SurfaceEvent(Controls.boardBankPrev, ControlKind.button, 1));
    expect(booth.board.bank, 0);
    await binding.handle(SurfaceEvent(Controls.boardLevel, ControlKind.fader, 0.5));
    expect(booth.board.doc.level, 0.5);
    await binding.handle(SurfaceEvent(Controls.boardStop, ControlKind.button, 1));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(booth.board.anySounding, isFalse);
    expect(lit['board.pad.1'], isFalse);
    binding.detach();
  });

  test('the wire says the board and what is sounding, and both read back', () async {
    final b = booth.board;
    await b.press(0, 0);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final msg = LinkWire.boardMessage(b, light: true);
    expect(msg['t'], 'board');
    expect(msg['light'], isTrue);
    expect((msg['peaks'] as Map).containsKey('${SampleKit.impact}'), isTrue, reason: 'a warmed kit sound has a shape');
    final doc = BoardDoc.fromJson((msg['doc'] as Map).cast<String, dynamic>());
    expect(doc.pad(0, 0)!.name, 'IMPACT');
    final pads = msg['pads'] as List;
    expect(pads.single['pad'], 0);
    expect(pads.single['elapsed_ms'], inInclusiveRange(0, 200));
    expect(pads.single['len_ms'], 1000);
    final back = LinkWire.decode(LinkWire.encode(msg));
    expect(back!['t'], 'board');
    expect(LinkWire.decode('not json'), isNull);
  });
}
