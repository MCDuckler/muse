// The trained separator from the app's side: fetching what it needs, choosing it over
// the arithmetic, and falling back to the arithmetic when it cannot run.
//
// The last test runs the real thing — the real program, the real network — and is
// skipped unless it is pointed at them:
//
//   WETOWL_SEPARATE=build/separator/bundle/bin/wetowl_separate \
//   WETOWL_KIT_SOURCE=<a folder with scnet-small-v1.onnx.gz and the runtime's .gz> \
//   flutter test test/separation_kit_test.dart
@TestOn('vm')
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/worker/render_parts.dart';
import 'package:muse/src/worker/parts_jobs.dart';
import 'package:muse/src/worker/separation_kit.dart';

String? _onPath(String name) {
  for (final d in (Platform.environment['PATH'] ?? '').split(':')) {
    if (d.isEmpty) continue;
    final f = File('$d/$name');
    if (f.existsSync()) return f.path;
  }
  return null;
}

/// A house with a /models/ folder, serving whatever [files] says.
Future<(HttpServer, String)> _house(Map<String, List<int>> files) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((r) async {
    final body = files[r.uri.path];
    if (body == null) {
      r.response.statusCode = 404;
    } else {
      r.response.add(body);
    }
    await r.response.close();
  });
  return (server, 'http://127.0.0.1:${server.port}');
}

void main() {
  late Directory dir;

  setUp(() {
    forgetHere();
    dir = Directory.systemTemp.createTempSync('muse-kit-');
    partsDirForTesting = dir.path;
    kitDirForTesting = dir.path;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    renderer = defaultRenderer;
    separationHouse = null;
    kitDirForTesting = null;
    separatorProgramForTesting = null;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('fetching', () {
    final content = List<int>.generate(100000, (i) => (i * 7919) % 251);
    final right = KitFile('thing.bin', sha256.convert(content).toString(), content.length);

    test('a file arrives whole, and only when it is the right one', () async {
      final (server, base) = await _house({'/models/thing.bin.gz': gzip.encode(content)});
      addTearDown(server.close);
      final into = File('${dir.path}/thing.bin');
      await fetchKitFile(Uri.parse('$base/models/thing.bin.gz'), right, into);
      expect(into.readAsBytesSync(), content);
      expect(File('${into.path}.part').existsSync(), isFalse);
    });

    test('a file that is not what it should be is not kept', () async {
      final wrong = [...content]..[500] ^= 1;
      final (server, base) = await _house({'/models/thing.bin.gz': gzip.encode(wrong)});
      addTearDown(server.close);
      final into = File('${dir.path}/thing.bin');
      await expectLater(
          fetchKitFile(Uri.parse('$base/models/thing.bin.gz'), right, into), throwsStateError);
      expect(into.existsSync(), isFalse, reason: 'no file with the real name');
      expect(File('${into.path}.part').existsSync(), isFalse, reason: 'and no leftovers');
    });

    test('a house without the file says so', () async {
      final (server, base) = await _house({});
      addTearDown(server.close);
      await expectLater(
          fetchKitFile(Uri.parse('$base/models/thing.bin.gz'), right, File('${dir.path}/x')),
          throwsA(isA<HttpException>()));
    });
  });

  test('with the separator, one pass makes all four parts, newer than the old ones',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    separationHouse = () => 'http://example.invalid';
    separatorOffForTesting = false;
    final asked = <Map<String, String>>[];
    renderer = (audio, name, into) async {
      asked.add(into);
      for (final f in into.values) {
        File(f).writeAsBytesSync([1]);
      }
    };
    expect((await partHere('song.m4a', 5, 'drums')).$1, Here.making);
    for (var i = 0; i < 200 && makingHere(5, 'drums'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(asked, hasLength(1));
    expect(asked.single.keys.toSet(), trainedParts.toSet());
    expect(asked.single.values.every((f) => RegExp('-v$partsVersion\\.(m4a|opus)\$').hasMatch(f)), isTrue);
    expect(asked.single['stems'], endsWith('.opus'), reason: 'the six-channel stems are Opus');
    for (final p in trainedParts) {
      expect((await partHere('song.m4a', 5, p)).$1, Here.ready, reason: p);
    }
    expect(asked, hasLength(1), reason: 'one pass for all four');
  });

  test('an old part is used only where the separator cannot run', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    File('${dir.path}/6-drums-v1.m4a').writeAsBytesSync([1]);

    separatorOffForTesting = true;
    expect((await partHere('song.m4a', 6, 'drums')).$1, Here.ready);

    forgetHere();
    separatorOffForTesting = false;
    renderer = (audio, name, into) async {};
    expect((await partHere('song.m4a', 6, 'drums')).$1, Here.making,
        reason: 'a computer that has the separator makes the better part');
  });

  test('startup throws away old parts that have been bettered', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    File('${dir.path}/8-drums-v1.m4a').writeAsBytesSync([1]);
    File('${dir.path}/8-drums-v2.m4a').writeAsBytesSync([1]);
    File('${dir.path}/9-drums-v1.m4a').writeAsBytesSync([1]);
    File('${dir.path}/scnet.onnx.part').writeAsBytesSync([1]);
    await sweepHere();
    expect(File('${dir.path}/8-drums-v1.m4a').existsSync(), isFalse);
    expect(File('${dir.path}/8-drums-v2.m4a').existsSync(), isTrue);
    expect(File('${dir.path}/9-drums-v1.m4a').existsSync(), isTrue,
        reason: 'still the only drums track 9 has');
    expect(File('${dir.path}/scnet.onnx.part').existsSync(), isFalse);
  });

  final ffmpeg = _onPath('ffmpeg');

  File makeSong(String name, int seconds) {
    final song = File('${dir.path}/$name');
    final made = Process.runSync(ffmpeg!, [
      '-v', 'error', '-y',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=$seconds',
      '-f', 'lavfi', '-i', 'anoisesrc=d=$seconds:c=pink:a=0.3',
      '-filter_complex', '[0][1]amix=inputs=2:duration=first,pan=stereo|c0=c0|c1=c0',
      '-c:a', 'aac', song.path,
    ]);
    expect(made.exitCode, 0, reason: '${made.stderr}');
    return song;
  }

  Future<void> waitFor(int id, String name, {int seconds = 60}) async {
    for (var i = 0; i < seconds * 20 && makingHere(id, name); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('when the separator cannot be had, the arithmetic takes the record apart',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    // A house that has nothing, and no program beside the test: the separator is
    // tried, fails, and the old way still delivers.
    final (server, base) = await _house({});
    addTearDown(server.close);
    separationHouse = () => base;
    separatorOffForTesting = false;
    final song = makeSong('song.m4a', 4);

    expect((await partHere(song.path, 11, 'drums')).$1, Here.making);
    await waitFor(11, 'drums');
    final drums = await partHere(song.path, 11, 'drums');
    expect(drums.$1, Here.ready);
    expect(drums.$2, endsWith('-v1.m4a'), reason: 'made by the arithmetic');
    expect((await partHere(song.path, 11, 'music')).$1, Here.ready);
  },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: ffmpeg == null ? 'no ffmpeg on this machine' : null);

  test('a record the separator cannot take apart is made the old way, once', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    // A separator that is all there — program and files — but fails on this record.
    final failing = File('${dir.path}/fails.sh')
      ..writeAsStringSync('#!/bin/sh\necho "cannot read that" >&2\nexit 4\n');
    Process.runSync('chmod', ['+x', failing.path]);
    separatorProgramForTesting = failing.path;
    for (final f in [modelFile, runtimeFile!]) {
      final raf = File('${dir.path}/${f.name}').openSync(mode: FileMode.write);
      raf.truncateSync(f.bytes); // the right size is what is checked before each use
      raf.closeSync();
    }
    separationHouse = () => 'http://127.0.0.1:9'; // never asked: the files are here
    final song = makeSong('song.m4a', 3);

    expect((await partHere(song.path, 31, 'drums')).$1, Here.making);
    await waitFor(31, 'drums');
    final drums = await partHere(song.path, 31, 'drums');
    expect(drums.$1, Here.ready, reason: 'the arithmetic made it');
    expect(drums.$2, endsWith('-v1.m4a'));
    expect(makingHere(31, 'drums'), isFalse, reason: 'and nobody is trying again');
  },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: ffmpeg == null || !Platform.isLinux ? 'needs ffmpeg, on Linux' : null);

  final program = Platform.environment['WETOWL_SEPARATE'];
  final source = Platform.environment['WETOWL_KIT_SOURCE'];
  test('the real separator: fetched once, four parts out, as long as the record',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final served = <String, List<int>>{};
    for (final f in [modelFile, runtimeFile!]) {
      served['/models/${f.name}.gz'] = File('$source/${f.name}.gz').readAsBytesSync();
    }
    final (server, base) = await _house(served);
    addTearDown(server.close);
    separationHouse = () => base;
    final song = makeSong('song.m4a', 20);
    final stages = <PartsStage>[];
    var sawProgress = false;
    void heard() {
      final j = partsJobs.of(21);
      if (j == null) return;
      if (stages.isEmpty || stages.last != j.stage) stages.add(j.stage);
      if (j.stage == PartsStage.separating && (j.progress ?? 0) > 0) sawProgress = true;
    }

    partsJobs.addListener(heard);
    addTearDown(() => partsJobs.removeListener(heard));

    expect((await partHere(song.path, 21, 'instrumental')).$1, Here.making);
    await waitFor(21, 'instrumental', seconds: 300);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(stages, containsAllInOrder(
        [PartsStage.gettingSeparator, PartsStage.separating, PartsStage.ready]));
    expect(sawProgress, isTrue, reason: 'the list shows how far through it is');
    expect(partsJobs.of(21)!.trained, isTrue);
    for (final p in trainedParts) {
      final (state, path) = await partHere(song.path, 21, p);
      expect(state, Here.ready, reason: p);
      expect(path, endsWith('-v2.m4a'), reason: 'made by the separator');
      final probe = Process.runSync(ffmpeg!.replaceAll('ffmpeg', 'ffprobe'), [
        '-v', 'error', '-show_entries', 'stream=sample_rate,channels:format=duration',
        '-of', 'default=nw=1', path!,
      ]);
      final said = probe.stdout as String;
      expect(said, contains('sample_rate=32000'));
      expect(said, contains('channels=2'));
      final d = double.parse(RegExp(r'duration=([\d.]+)').firstMatch(said)!.group(1)!);
      expect(d, closeTo(20, 0.2), reason: '$p as long as the record');
    }
    expect(File('${dir.path}/${modelFile.name}').lengthSync(), modelFile.bytes);
    expect(dir.listSync().where((f) => f.path.contains('.tmp.')), isEmpty);
  },
      timeout: const Timeout(Duration(minutes: 6)),
      skip: ffmpeg == null || program == null || source == null
          ? 'needs WETOWL_SEPARATE, WETOWL_KIT_SOURCE and ffmpeg'
          : null);

  // On a computer with an NVIDIA card and its libraries: the CUDA build is fetched and
  // the parts are made on the card. Elsewhere the same record is simply made on the
  // processor, which the test above covers.
  test('the real separator on the graphics card, where there is one', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    forgetCudaForTesting();
    if (!await cudaHere(program!)) {
      markTestSkipped('no NVIDIA card with CUDA 13 and cuDNN 9 here');
      return;
    }
    final served = <String, List<int>>{};
    for (final f in [modelFile, runtimeFile!, ...cudaFiles!]) {
      served['/models/${f.name}.gz'] = File('$source/${f.name}.gz').readAsBytesSync();
    }
    final (server, base) = await _house(served);
    addTearDown(server.close);
    separationHouse = () => base;
    final song = makeSong('song.m4a', 20);
    final clock = Stopwatch()..start();
    expect((await partHere(song.path, 22, 'drums')).$1, Here.making);
    await waitFor(22, 'drums', seconds: 600);
    for (final f in cudaFiles!) {
      expect(File('${dir.path}/${f.name}').lengthSync(), f.bytes, reason: f.name);
    }
    expect(File('${dir.path}/${runtimeFile!.name}').existsSync(), isFalse,
        reason: 'the processor\'s runtime is only fetched when the card cannot be used');
    for (final p in trainedParts) {
      expect((await partHere(song.path, 22, p)).$1, Here.ready, reason: p);
    }
    debugPrint('twenty seconds taken apart on the card in ${clock.elapsed}, fetch included');
  },
      timeout: const Timeout(Duration(minutes: 12)),
      skip: ffmpeg == null || program == null || source == null
          ? 'needs WETOWL_SEPARATE, WETOWL_KIT_SOURCE and ffmpeg'
          : null);
}
