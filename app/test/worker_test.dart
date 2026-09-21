// This computer fetching music for the house.
//
// Nothing here touches YouTube or a server: the programs are a script of answers and the
// server writes down what it was told. What is held to is what the Python worker learnt
// the hard way — a rate limit that reads as "Video unavailable" must give the song back,
// not kill it; an age check that reads like a bot check must not put the downloader to
// sleep — and the loop around it: a few at a time, fewer after a push-back, everything
// given back on the way out, and nothing left on this computer's disk.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/worker/downloader.dart';
import 'package:muse/src/worker/tools.dart';
import 'package:muse/src/worker/ytdlp.dart';

class PretendServer implements IngestServer {
  final waiting = <IngestJob>[];
  final completed = <(IngestJob, Map<String, dynamic>, int)>[];
  final failed = <(IngestJob, String, bool)>[];
  final released = <IngestJob>[];
  final leases = <({int limit, int busy, bool urgentOnly})>[];
  Object? refuse;

  @override
  Future<List<IngestJob>> lease(
      {required int limit, required int busy, bool urgentOnly = false, int wait = 0}) async {
    if (refuse != null) throw refuse!;
    leases.add((limit: limit, busy: busy, urgentOnly: urgentOnly));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final out = <IngestJob>[];
    while (out.length < limit && waiting.isNotEmpty) {
      out.add(waiting.removeAt(0));
    }
    return out;
  }

  @override
  Future<void> progress(IngestJob job, String stage, {double? percent, String? speed}) async {}

  @override
  Future<void> complete(IngestJob job, File audio, Map<String, dynamic> meta) async =>
      completed.add((job, meta, await audio.length()));

  @override
  Future<void> fail(IngestJob job, String reason, {required bool retryable}) async =>
      failed.add((job, reason, retryable));

  @override
  Future<void> release(IngestJob job) async => released.add(job);
}

/// yt-dlp, ffprobe and ffmpeg, played by a function.
class PretendPrograms implements Runner {
  PretendPrograms(this.ytdlp);

  /// What yt-dlp prints and how it exits; a file is written when it exits 0.
  final ({List<String> lines, int code, String ext, Duration takes}) Function(String videoId) ytdlp;
  final ran = <List<String>>[];
  final dirs = <String>[];

  @override
  Future<int> stream(String exe, List<String> args, void Function(String) onLine) async {
    ran.add([exe, ...args]);
    final id = args.last.split('v=').last;
    final out = args[args.indexOf('-o') + 1];
    final dir = out.substring(0, out.lastIndexOf('/'));
    dirs.add(dir);
    final play = ytdlp(id);
    await Future<void>.delayed(play.takes);
    play.lines.forEach(onLine);
    if (play.code == 0) await File('$dir/$id.${play.ext}').writeAsBytes(List.filled(2048, 7));
    return play.code;
  }

  @override
  Future<({int code, String out, String err})> run(String exe, List<String> args) async {
    ran.add([exe, ...args]);
    if (exe == 'ffprobe') {
      return (
        code: 0,
        out: '{"streams":[{"codec_name":"aac"}],"format":{"duration":"201.5","bit_rate":"129400"}}',
        err: ''
      );
    }
    if (args.contains('ebur128=framelog=quiet')) {
      return (code: 0, out: '', err: '  Integrated loudness:\n    I:         -10.9 LUFS\n');
    }
    // A conversion: write what it was asked to.
    await File(args.last).writeAsBytes(List.filled(1024, 9));
    return (code: 0, out: '', err: '');
  }
}

Future<Tools> allThere() async => Tools(
    ytdlp: 'yt-dlp', ffmpeg: 'ffmpeg', ffprobe: 'ffprobe', js: (name: 'node', path: 'node'));

IngestJob job(int id, String video, {int priority = 100}) =>
    IngestJob(id: id, trackId: id * 10, videoId: video, priority: priority);

Future<void> until(bool Function() done, {int ms = 3000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: 'waited ${ms}ms for it');
}

void main() {
  group('what yt-dlp is asked, and what it says', () {
    test('one song, as a list of arguments and never a sentence', () {
      final args = ytdlpArgs(videoId: '4D7u5KF7SP8', outDir: '/tmp/x', jsRuntime: 'node');
      expect(args, containsAllInOrder(['--js-runtimes', 'node']));
      expect(args, containsAllInOrder(['-f', '140/bestaudio[acodec^=mp4a]/bestaudio']));
      expect(args.last, 'https://music.youtube.com/watch?v=4D7u5KF7SP8');
      expect(args, contains('--no-playlist'));
      expect(args, isNot(contains('--no-warnings')), reason: 'the 429 arrives as a warning');
    });

    test('an id that is not an id never reaches a command line', () {
      for (final bad in ['--exec=rm', 'abc', '4D7u5KF7SP8 ; ls', '../../etc/pw']) {
        expect(() => ytdlpArgs(videoId: bad, outDir: '/tmp', jsRuntime: 'node'),
            throwsArgumentError, reason: bad);
      }
    });

    test('progress is read, and the last word is remembered', () {
      final p = YtdlpLine.read('MUSEPROGRESS  42.5% 1.20MiB/s');
      expect(p.percent, closeTo(0.425, 1e-9));
      expect(p.speed, '1.20MiB/s');
      expect(YtdlpLine.read('[youtube] 4D7u: Downloading webpage').error, isNull);
      expect(YtdlpLine.read('ERROR: [youtube] x: Video unavailable').error,
          contains('Video unavailable'));
      expect(YtdlpLine.read('WARNING: HTTP Error 429: Too Many Requests').throttled, isTrue);
    });

    test('the verdicts that each cost somebody a night', () {
      // A rate limit shows as "Video unavailable". Classify the cause, not the symptom.
      expect(judge(lastError: 'ERROR: Video unavailable', throttled: true), Verdict.backOff);
      // One word apart, and only one of them is about the song.
      expect(judge(lastError: "Sign in to confirm you're not a bot", throttled: false),
          Verdict.backOff);
      expect(judge(lastError: 'Sign in to confirm your age', throttled: false),
          Verdict.needsAge);
      expect(judge(lastError: 'ERROR: Private video', throttled: false), Verdict.dead);
      expect(judge(lastError: 'ERROR: unable to download: connection reset', throttled: false),
          Verdict.retry);
    });

    test('loudness is measured, and the gain that levels it worked out', () {
      final l = loudnessFrom('Summary:\n  Integrated loudness:\n    I:         -10.9 LUFS\n');
      expect(l.lufs, -10.9);
      expect(l.gainDb, -3.1);
      expect(loudnessFrom('nothing').lufs, isNull);
    });
  });

  group('the downloader', () {
    late PretendServer server;
    late Directory work;

    setUp(() async {
      server = PretendServer();
      work = await Directory.systemTemp.createTemp('wetowl-test-');
    });
    tearDown(() => work.delete(recursive: true));

    test('a song is fetched, looked at, handed over, and nothing is left here', () async {
      server.waiting.add(job(1, '4D7u5KF7SP8'));
      final programs = PretendPrograms((id) => (
            lines: ['[youtube] $id: Downloading', 'MUSEPROGRESS  50.0% 1MiB/s'],
            code: 0,
            ext: 'm4a',
            takes: const Duration(milliseconds: 10),
          ));
      final d = Downloader(server: server, findTools: allThere, runner: programs, workDir: work);
      await d.start();
      await until(() => server.completed.isNotEmpty);
      await d.stop();

      final (done, meta, bytes) = server.completed.single;
      expect(done.id, 1);
      expect(bytes, 2048);
      expect(meta, containsPair('track_id', 10));
      expect(meta, containsPair('codec', 'aac'));
      expect(meta, containsPair('duration_ms', 201500));
      expect(meta, containsPair('loudness_lufs', -10.9));
      expect(meta, containsPair('gain_db', -3.1));
      expect(d.done, 1);
      expect(programs.ran.where((r) => r.contains('-c:a')), isEmpty,
          reason: 'already AAC in an m4a: a copy, not a transcode');
      expect(work.listSync(), isEmpty, reason: "this computer's disk is not the archive");
    });

    test('anything that is not an m4a is made into one', () async {
      server.waiting.add(job(2, 'H4RELGc9su8'));
      final programs = PretendPrograms((id) =>
          (lines: const [], code: 0, ext: 'webm', takes: Duration.zero));
      final d = Downloader(server: server, findTools: allThere, runner: programs, workDir: work);
      await d.start();
      await until(() => server.completed.isNotEmpty);
      await d.stop();
      expect(programs.ran.where((r) => r.contains('-c:a')), hasLength(1));
      expect(server.completed.single.$3, 1024, reason: 'the converted file is what goes up');
    });

    test('throttled: the song is given back, not failed, and it stops asking', () async {
      server.waiting.addAll([job(3, 'AAAAAAAAAAA'), job(4, 'BBBBBBBBBBB')]);
      final programs = PretendPrograms((id) => (
            lines: [
              'WARNING: [youtube] HTTP Error 429: Too Many Requests',
              'ERROR: [youtube] $id: Video unavailable',
            ],
            code: 1,
            ext: 'm4a',
            takes: const Duration(milliseconds: 10),
          ));
      final d = Downloader(
          server: server, findTools: allThere, runner: programs, workDir: work, maxSlots: 2);
      await d.start();
      await until(() => server.released.length == 2);
      await until(() => d.state == DownloaderState.coolingDown);

      expect(server.failed, isEmpty, reason: 'nothing is wrong with the songs');
      expect(d.coolingUntil!.isAfter(DateTime.now()), isTrue);
      expect(d.slots, 1, reason: 'and fewer at a time from here on, never below one');
      final asked = server.leases.length;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(server.leases.skip(asked).every((l) => l.limit == 0), isTrue,
          reason: 'visibly alive, asking for nothing');
      await d.stop();
    });

    test('an age check is about the song, and does not put it to sleep', () async {
      server.waiting.add(job(5, 'CCCCCCCCCCC'));
      final programs = PretendPrograms((id) => (
            lines: ['ERROR: [youtube] $id: Sign in to confirm your age.'],
            code: 1,
            ext: 'm4a',
            takes: Duration.zero,
          ));
      final d = Downloader(server: server, findTools: allThere, runner: programs, workDir: work);
      await d.start();
      await until(() => server.failed.isNotEmpty);
      await d.stop();
      final (_, reason, retryable) = server.failed.single;
      expect(retryable, isFalse);
      expect(reason, contains('age-verified'));
      expect(d.coolingUntil, isNull);
      expect(server.released, isEmpty);
    });

    test('while somebody is waiting for a song, nothing else is taken', () async {
      server.waiting.add(job(6, 'DDDDDDDDDDD', priority: 50));
      final programs = PretendPrograms((id) => (
            lines: const [], code: 0, ext: 'm4a', takes: const Duration(milliseconds: 250)));
      final d = Downloader(
          server: server, findTools: allThere, runner: programs, workDir: work, maxSlots: 3);
      await d.start();
      await until(() => d.inFlight.isNotEmpty);
      await until(() => server.leases.any((l) => l.busy == 1));
      expect(server.leases.where((l) => l.busy == 1).every((l) => l.urgentOnly), isTrue);
      await until(() => server.completed.isNotEmpty);
      await d.stop();
    });

    test('stopping gives back what it was holding', () async {
      server.waiting.add(job(7, 'EEEEEEEEEEE'));
      final programs = PretendPrograms((id) =>
          (lines: const [], code: 0, ext: 'm4a', takes: const Duration(seconds: 2)));
      final d = Downloader(server: server, findTools: allThere, runner: programs, workDir: work);
      await d.start();
      await until(() => d.inFlight.isNotEmpty);
      await d.stop();
      expect(server.released.single.id, 7);
      expect(d.state, DownloaderState.off);
      // The download that was running finishes into nothing: it is not handed over.
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      expect(server.completed, isEmpty);
    });

    test('without the programs it says which, and what to type', () async {
      final d = Downloader(
          server: server,
          findTools: () async => Tools(ytdlp: null, ffmpeg: 'ffmpeg', ffprobe: 'ffprobe', js: null),
          runner: PretendPrograms((_) => (lines: const [], code: 0, ext: 'm4a', takes: Duration.zero)),
          workDir: work);
      await d.start();
      expect(d.state, DownloaderState.noTools);
      expect(d.problem, contains('yt-dlp'));
      expect(d.problem, contains('node or deno'));
      expect(d.running, isFalse);
      expect(server.leases, isEmpty, reason: 'nothing is asked for that cannot be done');
    });

    test('a server that says no is believed', () async {
      server.refuse = IngestRefused('this device has not been allowed to fetch music');
      final d = Downloader(
          server: server,
          findTools: allThere,
          runner: PretendPrograms((_) => (lines: const [], code: 0, ext: 'm4a', takes: Duration.zero)),
          workDir: work);
      await d.start();
      await until(() => d.state == DownloaderState.refused);
      expect(d.problem, contains('not been allowed'));
      expect(d.running, isFalse);
    });
  });
}
