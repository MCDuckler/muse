// The real thing, with a real ffmpeg: a record in, two parts out.
//
// separate_test.dart checks the arithmetic and parts_test.dart checks which machine
// is asked. This checks the glue between them — decoding with ffmpeg, handing the
// samples to an isolate, and writing what comes back — because that is where a
// mistake is invisible to both of the others and obvious to anybody listening.
//
// Skipped where there is no ffmpeg, which is every machine that could not do this
// for real anyway.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/worker/render_parts.dart';

String? findFfmpeg() {
  for (final d in (Platform.environment['PATH'] ?? '').split(':')) {
    if (d.isEmpty) continue;
    final f = File('$d/ffmpeg');
    if (f.existsSync()) return f.path;
  }
  return null;
}

void main() {
  final ffmpeg = findFfmpeg();

  test('a record goes in and its parts come out, playable and the right length',
      () async {
    final dir = Directory.systemTemp.createTempSync('muse-render-');
    addTearDown(() => dir.deleteSync(recursive: true));
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    forgetHere();
    partsDirForTesting = dir.path;

    // Six seconds of something with both a note and a beat in it, so there is
    // genuinely something for the separation to divide.
    final song = File('${dir.path}/song.m4a');
    final made = Process.runSync(ffmpeg!, [
      '-v', 'error', '-y',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=6',
      '-f', 'lavfi', '-i', 'anoisesrc=d=6:c=pink:a=0.3',
      '-filter_complex', '[1]atrim=0:0.03,apad=whole_dur=0.25,aloop=loop=23:size=8000[hits];'
          '[0][hits]amix=inputs=2:duration=first,pan=stereo|c0=c0|c1=c0',
      '-c:a', 'aac', song.path,
    ]);
    expect(made.exitCode, 0, reason: '${made.stderr}');

    var answer = await partHere(song.path, 77, 'drums');
    expect(answer.$1, Here.making);
    for (var i = 0; i < 600 && makingHere(77, 'drums'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    answer = await partHere(song.path, 77, 'drums');
    expect(answer.$1, Here.ready, reason: 'it was made here');
    final drums = File(answer.$2!);
    expect(drums.existsSync(), isTrue);
    expect(drums.lengthSync(), greaterThan(1000));

    // The other half came out of the same pass.
    final music = await partHere(song.path, 77, 'music');
    expect(music.$1, Here.ready, reason: 'one pass gives both halves');

    // And what was written is audio, as long as the record it came from. A part that
    // stops early is silence on a deck, which is the one failure nobody would notice
    // until it happened in front of people.
    for (final part in [drums, File(music.$2!)]) {
      final probe = Process.runSync(ffmpeg.replaceAll('ffmpeg', 'ffprobe'), [
        '-v', 'error', '-show_entries', 'format=duration',
        '-of', 'csv=p=0', part.path,
      ]);
      expect(probe.exitCode, 0, reason: '${probe.stderr}');
      expect(double.parse((probe.stdout as String).trim()), closeTo(6, 0.2),
          reason: 'as long as the record: ${part.path}');
    }

    // Nothing half-written left behind.
    expect(dir.listSync().where((f) => f.path.endsWith('.tmp.m4a')), isEmpty);
  },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: ffmpeg == null ? 'no ffmpeg on this machine' : null);
}
