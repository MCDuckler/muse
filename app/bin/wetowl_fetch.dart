// wetowl-fetch: this computer working for the pool — fetching music and taking records
// apart for the whole house — with no window.
//
// The app can do the fetching itself, but only while it is open, and a computer that
// is on all day is not a computer with a music player open all day. This is the same
// downloader — the same file, lib/src/worker/downloader.dart — in a program that has
// nothing else in it, so it can be started when somebody logs in and left alone.
//
// It is told what to do by a file the app writes (fetcher.json: where the server is,
// the token this device signs in with, how many at a time) and says what it is doing in
// another (fetcher-status.json), which is what the app's "This computer" page reads. It
// is stopped the same way, by the file saying so or going away: a signal would do on
// Linux, but Windows has no polite one, and a downloader killed outright leaves its
// songs locked for the ten minutes their leases last.
//
//   wetowl-fetch --config /path/to/fetcher.json
import 'dart:async';
import 'dart:io';

import 'package:muse/src/worker/downloader.dart';
import 'package:muse/src/worker/helper_files.dart';
import 'package:muse/src/worker/ingest_http.dart';
import 'package:muse/src/worker/separation_kit.dart';
import 'package:muse/src/worker/splitter.dart';
import 'package:muse/src/worker/status.dart';
import 'package:muse/src/worker/tools.dart';

Future<void> main(List<String> args) async {
  final at = args.indexOf('--config');
  if (at < 0 || at + 1 >= args.length) {
    stderr.writeln('usage: wetowl-fetch --config <fetcher.json>');
    exit(64);
  }
  final files = HelperFiles(File(args[at + 1]).parent);
  var config = await files.readConfig();
  if (config == null || !config.on) {
    stderr.writeln('nothing to do: ${files.config.path} is missing or switched off');
    exit(0);
  }

  // One fetcher to a computer, whichever program it is: the app takes the same lock.
  final RandomAccessFile lock;
  try {
    lock = await files.lock.open(mode: FileMode.append);
    await lock.lock(FileLock.exclusive);
  } catch (_) {
    stderr.writeln('another WetOwl on this computer is already fetching');
    exit(0);
  }

  late final Splitter splitter;
  // What this computer says about itself with every request for work (pool.py).
  Map<String, dynamic> said() => {
        'fetch': config!.fetch,
        'split': config!.split && splitter.state != SplitterState.noSeparator,
        'gpu': splitter.gpu,
        'cores': Platform.numberOfProcessors,
        'platform': Platform.operatingSystem,
        'background': true,
        'slots': config!.slots,
      };
  final downloader = Downloader(
    server: HttpIngestServer(
        baseUrl: () => config!.server, token: () => config!.token, pool: said),
    findTools: () => Tools.find(own: files.tools),
    maxSlots: config.slots,
  );
  separatorSays = (line) => stderr.writeln(line);
  splitter = Splitter(
    server: HttpSplitServer(baseUrl: () => config!.server, token: () => config!.token),
    appFolder: files.dir,
    findFfmpeg: () async => (await Tools.find(own: files.tools)).ffmpeg,
    pool: said,
  );

  // Said at most once a second however fast things change, and at least every five
  // so that whoever reads it can tell a quiet downloader from a dead one.
  Timer? soon;
  String? build;
  try {
    build = File('${File(Platform.resolvedExecutable).parent.path}'
            '${Platform.pathSeparator}build-stamp.txt')
        .readAsStringSync()
        .trim();
  } catch (_) {}
  Future<void> say() => files.writeStatus(
      FetchStatus.of(downloader, pid: pid, splitter: splitter, build: build));
  void changed() => soon ??= Timer(const Duration(seconds: 1), () {
        soon = null;
        say();
      });
  downloader.addListener(changed);
  splitter.addListener(changed);
  final heartbeat = Timer.periodic(const Duration(seconds: 5), (_) => say());

  var leaving = false;
  Future<void> leave(String why) async {
    if (leaving) return;
    leaving = true;
    heartbeat.cancel();
    soon?.cancel();
    await downloader.stop();
    await splitter.stop();
    await files.writeStatus(FetchStatus(
      state: DownloaderState.off,
      done: downloader.done,
      failed: downloader.failed,
      log: [...downloader.log.skip(downloader.log.length > 59 ? downloader.log.length - 59 : 0), why],
      at: DateTime.now(),
    ));
    await lock.unlock();
    await lock.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => leave('stopped — interrupted'));
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => leave('stopped — asked to by the system'));
  }

  if (config.fetch) await downloader.start();
  if (config.split) await splitter.start();
  await say();

  // The file is the switch.
  Timer.periodic(const Duration(seconds: 3), (_) async {
    final next = await files.readConfig();
    if (next == null || !next.on) return leave('stopped — switched off in WetOwl');
    if (next.slots != config!.slots) {
      downloader
        ..maxSlots = next.slots
        ..slots = next.slots;
    }
    config = next;
    // Either kind of work switched off or on in the app.
    if (!next.fetch && downloader.running) await downloader.stop();
    if (!next.split && splitter.running) await splitter.stop();
    if (next.split && !splitter.running && splitter.state != SplitterState.noSeparator) {
      await splitter.start();
    }
    // Told no, or nothing to fetch with: say so and stay, so that the page can show
    // why — and try again when the file changes, which is what installing the missing
    // program and pressing "Look again" does.
    if (next.fetch && !downloader.running &&
        (next.stamp != _tried || downloader.state == DownloaderState.off)) {
      _tried = next.stamp;
      await downloader.start();
    }
  });
  _tried = config!.stamp;
}

int _tried = 0;
