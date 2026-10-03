// The MIDI path end to end on a Linux box with no hardware: a pretend Hercules RMX
// on the ALSA sequencer (tool/fake_midi_controller.c), found by the real transport,
// matched to the shipped layout, its PLAY starting deck A, and the light coming back.
//
// Skipped where there is no ALSA sequencer or no C compiler.
@Tags(['linux-midi'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_midi_command_linux/flutter_midi_command_linux.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/control/layout.dart';
import 'package:muse/src/state/booth/control/manager.dart';
import 'package:muse/src/state/booth/control/midi_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'booth_test.dart' show NotedMixer, song, grid;
import 'fake_audio.dart';

Future<T?> eventually<T>(FutureOr<T?> Function() probe, {Duration within = const Duration(seconds: 6)}) async {
  final until = DateTime.now().add(within);
  while (DateTime.now().isBefore(until)) {
    final v = await probe();
    if (v != null) return v;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final canRun = Platform.isLinux &&
      File('/dev/snd/seq').existsSync() &&
      Process.runSync('which', ['gcc']).exitCode == 0;

  test('a fake RMX on the sequencer drives deck A and gets its PLAY light', () async {
    final dir = Directory.systemTemp.createTempSync('wetowl-fake-midi');
    addTearDown(() => dir.deleteSync(recursive: true));
    final bin = '${dir.path}/fake_midi_controller';
    final cc = Process.runSync('gcc', ['-O2', '-o', bin, 'tool/fake_midi_controller.c', '-lasound']);
    expect(cc.exitCode, 0, reason: '${cc.stderr}');
    final fake = await Process.start(bin, []);
    addTearDown(fake.kill);
    final said = <String>[];
    fake.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(said.add);
    final ready = Completer<void>();
    fake.stderr.transform(utf8.decoder).listen((s) {
      if (s.contains('client') && !ready.isCompleted) ready.complete();
    });
    await ready.future.timeout(const Duration(seconds: 5));

    SharedPreferences.setMockInitialValues({});
    FlutterMidiCommandLinux.registerWith();
    JustAudioPlatform.instance = FakeJustAudio();
    final booth = Booth(ApiClient(baseUrl: 'http://example.invalid')..token = 'x', mixer: NotedMixer());
    await booth.init();
    addTearDown(booth.dispose);
    booth.timing.put(1, grid(500));
    await booth.load(booth.a, song(1));

    final layouts = [ControllerLayout.parse(File('assets/controllers/hercules_dj_console_rmx.midi.json').readAsStringSync())];
    final m = ControllerManager(transports: [MidiTransport()], layouts: layouts, booth: booth);
    addTearDown(m.dispose);
    await m.start();

    final session = await eventually(() async {
      await m.rescan(quiet: true);
      return m.sessions.values.where((s) => s.device.name.contains('RMX')).firstOrNull;
    });
    expect(session, isNotNull, reason: 'found: ${m.found}\n${m.monitor.map((l) => l.text).join('\n')}');

    fake.stdin.writeln('B0 0B 7F');
    await fake.stdin.flush();
    expect(await eventually(() => booth.a.playing ? true : null), isTrue,
        reason: m.monitor.map((l) => '${l.raw} ${l.text}').join('\n'));
    // The light: the booth said PLAY is on, the fake console heard CC 0x0B = 0x7F.
    expect(await eventually(() => said.any((l) => l.contains('0B = 7F')) ? true : null), isTrue,
        reason: said.join('\n'));

    fake.stdin.writeln('B0 39 00');
    fake.stdin.writeln('B0 39 7F');
    await fake.stdin.flush();
    expect(await eventually(() => booth.crossfader == 1.0 ? true : null), isTrue);

    fake.kill();
    expect(await eventually(() => m.sessions.isEmpty ? true : null, within: const Duration(seconds: 8)), isTrue,
        reason: 'the device went and the session should have gone with it');
  }, skip: canRun ? false : 'needs Linux with an ALSA sequencer and gcc', timeout: const Timeout(Duration(minutes: 2)));
}
