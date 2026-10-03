// A phone and a desk, both this program, on the loopback: the desk's link server
// lets the phone in with the token, the phone's press fires the desk's pad through
// the controller manager and the one binding, and the desk's board comes back to
// the phone — the document first, then what sounds — so the phone shows it lit.
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/booth/board/board_store.dart';
import 'package:muse/src/state/booth/board/link_server_io.dart';
import 'package:muse/src/state/booth/board/pad_spec.dart';
import 'package:muse/src/state/booth/board/remote_board.dart';
import 'package:muse/src/state/booth/board/sampler.dart';
import 'package:muse/src/state/booth/board/samples.dart';
import 'package:muse/src/state/booth/board/soundboard.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/control/manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_audio.dart';
import 'soundboard_test.dart' show NotedMixer;

Future<void> until(bool Function() ok, String what, {Duration patience = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(patience);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('$what: not within $patience');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('com.ryanheise.audio_session'), (c) async => null);

  late Booth booth;
  late BoardLinkServer link;
  late ControllerManager manager;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
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
    link = BoardLinkServer(booth: () => booth);
    manager = ControllerManager(transports: [link], layouts: const [], booth: booth);
    await manager.start();
  });

  tearDown(() async {
    await manager.dispose();
    booth.dispose();
  });

  DeviceInfo desk() => DeviceInfo(id: 7, name: 'The desk', live: true, boardLink: link.advert);

  test('the desk listens, and says how to reach it', () async {
    expect(link.port, isNotNull);
    expect(link.token, hasLength(64));
    final ad = link.advert!;
    expect(ad['port'], link.port);
    expect(ad['addrs'], contains('127.0.0.1'));
  });

  test('a phone on the loopback: pressed there, fired here, lit there', () async {
    final phone = await RemoteBoard.connect(desk(), myName: 'iPad', relay: () => fail('direct wire expected'));
    expect(phone, isNotNull);
    expect(phone!.kind, 'LAN');
    await until(() => phone.ready, 'the board arrives');
    expect(phone.doc.pad(0, 0)!.name, 'IMPACT');
    expect(phone.peaksOf(SampleKit.impact), isNotNull, reason: 'the shape came with the board');
    await until(() => manager.sessions.length == 1, 'the desk connected the screen');
    expect(manager.sessions.values.single.device.name, 'iPad');

    await phone.press(0, 0);
    await until(() => booth.board.stateOf(0, 0).sounding, 'the desk fires the pad');
    await until(() => phone.stateOf(0, 0).sounding, 'the phone sees it sounding');
    expect(phone.anySounding, isTrue);
    expect(phone.lastFired!.name, 'IMPACT');
    expect(manager.monitor.any((l) => l.text.contains('board.pad.1')), isTrue, reason: 'in the monitor like a knob');

    // The hold, held from the phone: down then up.
    await phone.press(0, 4);
    await until(() => booth.board.stateOf(0, 4).held, 'held');
    await phone.release(0, 4);
    await until(() => !booth.board.stateOf(0, 4).sounding, 'let go');

    // The bank and the level follow the phone; the desk's doc change reaches the phone.
    await phone.showBank(2);
    await until(() => booth.board.bank == 2, 'bank');
    await phone.setLevel(0.3);
    await until(() => booth.board.doc.level == 0.3, 'level');
    await booth.board.setPad(2, 0, const PadSpec(sampleId: SampleKit.sweepUp, name: 'NEW ONE'));
    await until(() => phone.doc.pad(2, 0)?.name == 'NEW ONE', 'the phone hears the new pad');

    await phone.stopAll();
    await until(() => !booth.board.anySounding, 'quiet');
    await until(() => phone.rtt != null, 'a ping answered');
    expect(phone.rtt!.inMilliseconds, lessThan(1000));

    phone.dispose();
    await until(() => manager.sessions.isEmpty, 'the desk notices the phone left');
  });

  test('the wrong token is turned away', () async {
    final bad = DeviceInfo(id: 7, name: 'The desk', live: true, boardLink: {...link.advert!, 'token': 'nope'});
    var relayed = false;
    final phone = await RemoteBoard.connect(bad, myName: 'x', relay: () {
      relayed = true;
      return RelayLink(deskId: 7, post: (_, __) async {}, states: const Stream.empty());
    });
    expect(relayed, isTrue, reason: 'no direct wire: the relay is tried');
    expect(phone!.kind, 'RELAY');
    expect(manager.sessions, isEmpty);
    phone.dispose();
  });

  test('the relay: lines arrive through the server, the board goes out through it', () async {
    final out = <String>[];
    final sub = link.snapshots.stream.listen(out.add);
    link.relayIn('relay:9', 'A phone (relay)', [
      {'t': 'press', 'bank': 0, 'pad': 0, 'down': true},
    ]);
    await until(() => manager.sessions.length == 1, 'the relay peer connected');
    await until(() => booth.board.stateOf(0, 0).sounding, 'fired by relay');
    await until(() => out.any((l) => l.startsWith('{"t":"board"')), 'the board was said for the relay');
    await until(() => out.any((l) => l.startsWith('{"t":"playing"')), 'and what sounds');
    await sub.cancel();
  });
}
