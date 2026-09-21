// The windowless fetcher, from the app's side, and the files the two of them share.
//
// Everything said between them is a file, so everything that can go wrong is a file
// being missing, stale, half written or somebody else's — and those are the claims.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/worker/background.dart';
import 'package:muse/src/worker/downloader.dart';
import 'package:muse/src/worker/helper_files.dart';
import 'package:muse/src/worker/status.dart';
import 'package:muse/src/worker/told.dart';
import 'package:muse/src/worker/tools.dart';

void main() {
  late Directory dir;
  late HelperFiles files;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wetowl-bg-test');
    files = HelperFiles(dir);
  });
  tearDown(() => dir.delete(recursive: true));

  BackgroundFetcher fetcher({String exe = '/opt/wet owl/wetowl-fetch'}) => BackgroundFetcher(
        files: files,
        helper: File(exe),
        autostartDir: Directory('${dir.path}/autostart'),
        environment: const {'HOME': '/home/somebody'},
      );

  test('what it is told survives the trip, and rubbish is nothing', () async {
    await files.writeConfig(const HelperConfig(
        on: true, server: 'https://music.example', token: 'abc', slots: 2, stamp: 7));
    final back = await files.readConfig();
    expect(back!.on, isTrue);
    expect((back.server, back.token, back.slots, back.stamp),
        ('https://music.example', 'abc', 2, 7));

    await files.config.writeAsString('{"on": true, "server": "https://x"');
    expect(await files.readConfig(), isNull, reason: 'half a file');
    await files.config.writeAsString(jsonEncode({'on': true, 'server': 'https://x'}));
    expect(await files.readConfig(), isNull, reason: 'no token is no config');
  });

  test('the token is the user\'s alone on disk', () async {
    await files.writeConfig(const HelperConfig(on: true, server: 'https://x', token: 'secret'));
    final mode = (await files.config.stat()).mode & 0x1FF;
    expect(mode, 0x180, reason: 'rw for the owner and nothing for anybody else');
  }, skip: Platform.isWindows);

  test('switching it off takes the token out of the file', () async {
    final bg = fetcher();
    await files.writeConfig(const HelperConfig(on: true, server: 'https://x', token: 'secret'));
    await bg.stop();
    expect(await files.config.readAsString(), isNot(contains('secret')));
    expect((await files.readConfig())!.on, isFalse);
  });

  test('a status says what it was given, and knows when it has gone stale', () async {
    final said = FetchStatus(
      state: DownloaderState.working,
      slots: 2,
      inFlight: const [(videoId: 'abc123', stage: 'downloading', percent: 0.4, speed: '1MiB/s')],
      done: 5,
      failed: 1,
      log: const ['one', 'two'],
      pid: 42,
      at: DateTime.now(),
    );
    await files.writeStatus(said);
    final heard = (await files.readStatus())!;
    expect(heard.state, DownloaderState.working);
    expect(heard.running, isTrue);
    expect(heard.inFlight.single.videoId, 'abc123');
    expect(heard.inFlight.single.percent, 0.4);
    expect((heard.done, heard.failed, heard.pid), (5, 1, 42));
    expect(heard.fresh(), isTrue);
    expect(heard.fresh(now: DateTime.now().add(const Duration(minutes: 1))), isFalse,
        reason: 'a file goes on saying "fetching" after its writer has died');

    expect(FetchStatus.fromJson({'state': 'dancing'}), isNull);
    expect(FetchStatus.fromJson('nonsense'), isNull);
  });

  test('missing programs are not "running"', () {
    expect(const FetchStatus(state: DownloaderState.noTools).running, isFalse);
    expect(const FetchStatus(state: DownloaderState.refused).running, isFalse);
    expect(const FetchStatus(state: DownloaderState.coolingDown).running, isTrue);
  });

  group('starting at login', () {
    test('on Linux, a desktop entry with the paths quoted', () async {
      final bg = fetcher();
      final entry = bg.autostartEntry(windows: false);
      expect(entry, startsWith('[Desktop Entry]\n'));
      expect(entry, contains('Exec="/opt/wet owl/wetowl-fetch" --config "${files.config.path}"\n'));
      expect(entry, contains('Terminal=false'));
    });

    test('a path with a dollar or a quote in it cannot become a command', () {
      final entry = fetcher(exe: r'/opt/a"b$c`d/wetowl-fetch').autostartEntry(windows: false);
      expect(entry, contains(r'Exec="/opt/a\"b\$c\`d/wetowl-fetch"'));
    });

    test('on Windows, a script that starts it with no window', () {
      final entry = fetcher(exe: r'C:\Program Files\WetOwl\wetowl-fetch.exe')
          .autostartEntry(windows: true);
      expect(entry,
          contains(r'.Run """C:\Program Files\WetOwl\wetowl-fetch.exe"" --config ""'));
      expect(entry.trimRight(), endsWith(', 0, False'), reason: '0 is "hidden"');
    });

    test('it is written, found, and taken away again', () async {
      final bg = fetcher();
      expect(await bg.startsAtLogin, isFalse);
      await bg.setStartsAtLogin(true);
      expect(await bg.startsAtLogin, isTrue);
      expect(bg.autostartFile.path, startsWith(dir.path),
          reason: 'never somebody\'s real autostart folder from a test');
      await bg.setStartsAtLogin(false);
      expect(await bg.startsAtLogin, isFalse);
      await bg.setStartsAtLogin(false);
    }, skip: Platform.isWindows);
  });

  test('no helper beside the app means no background fetching on offer', () async {
    expect(await fetcher(exe: '${dir.path}/not-there').available, isFalse);
  });

  group('where to get what is missing', () {
    test('one link for each thing, ffmpeg and ffprobe together', () {
      final links = Tools.linksFor(['yt-dlp', 'ffmpeg', 'ffprobe', 'node or deno'], windows: true);
      expect(links.map((l) => l.name), ['yt-dlp', 'ffmpeg and ffprobe', 'Deno (or Node.js)']);
      expect(links.first.url, endsWith('/yt-dlp.exe'));
    });

    test('nothing for what is there, and only the projects\' own pages', () {
      expect(Tools.linksFor(const []), isEmpty);
      for (final windows in [true, false]) {
        for (final l in Tools.linksFor(['yt-dlp', 'ffprobe', 'node or deno'], windows: windows)) {
          final host = Uri.parse(l.url).host;
          expect(l.url, startsWith('https://'));
          expect(['github.com', 'www.gyan.dev', 'ffmpeg.org', 'deno.com'], contains(host));
        }
      }
    });
  });

  test('a listener that takes itself off while being told does not upset the rest', () {
    final told = Told();
    final heard = <String>[];
    late void Function() once;
    once = () {
      heard.add('once');
      told.removeListener(once);
    };
    told
      ..addListener(once)
      ..addListener(() => heard.add('always'));
    told.notifyListeners();
    told.notifyListeners();
    expect(heard, ['once', 'always', 'always']);
    told.dispose();
    told.notifyListeners();
    expect(heard.length, 3);
  });
}
