// A fragmented m4a made whole (worker/m4a_whole.dart): the same sound, sample for
// sample, in one plain file with its description in front. Judged by ffmpeg, which the
// app never needs but this machine has: the very same packets, and decoded, the very
// same sound as ffmpeg's own copy into a plain file — which is what yt-dlp's FixupM4a
// makes. (Not the same as decoding the pieces directly: ffmpeg reads a fragmented
// file's edit list differently, and plays a few milliseconds more at the end.)
// A real YouTube file can be tried as well with WETOWL_M4A_SAMPLE=<path>.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/worker/m4a_whole.dart';

bool get _ffmpeg {
  try {
    return Process.runSync('ffmpeg', ['-version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<String> _md5(List<String> args) async =>
    '${(await Process.run('ffmpeg', ['-v', 'error', ...args, '-f', 'md5', '-'])).stdout}'.trim();

/// The decoded sound's fingerprint, and what ffprobe makes of the file.
Future<(String, double, String)> _heard(String path) async {
  final md5 = await _md5(['-i', path]);
  final probe = await Process.run('ffprobe', [
    '-v', 'error', '-show_entries', 'format=duration,format_name', '-of',
    'default=nw=1', path,
  ]);
  final out = '${probe.stdout}';
  final duration =
      double.parse(RegExp(r'duration=([\d.]+)').firstMatch(out)!.group(1)!);
  return (md5, duration, out);
}

List<String> _topBoxes(Uint8List b) {
  final d = ByteData.sublistView(b);
  final out = <String>[];
  var at = 0;
  while (at + 8 <= b.length) {
    final size = d.getUint32(at);
    out.add(String.fromCharCodes(b.sublist(at + 4, at + 8)));
    if (size < 8) break;
    at += size;
  }
  return out;
}

Future<void> _same(String fragmented, Directory tmp) async {
  final src = await File(fragmented).readAsBytes();
  expect(_topBoxes(src), contains('moof'));
  final whole = wholeM4a(src);
  expect(whole, isNotNull);
  final out = File('${tmp.path}/whole.m4a')..writeAsBytesSync(whole!);
  expect(_topBoxes(whole), ['ftyp', 'moov', 'mdat'], reason: 'described first, in one piece');

  expect(await _md5(['-i', out.path, '-map', '0:a', '-c', 'copy']),
      await _md5(['-i', fragmented, '-map', '0:a', '-c', 'copy']),
      reason: 'the very same packets, nothing re-encoded');
  final reference = '${tmp.path}/ffmpeg.m4a';
  await Process.run(
      'ffmpeg', ['-v', 'error', '-y', '-i', fragmented, '-c', 'copy', '-f', 'mp4', reference]);
  final (a, aDuration, _) = await _heard(reference);
  final (b, bDuration, _) = await _heard(out.path);
  expect(b, a, reason: 'not one sample different from what ffmpeg makes of it');
  expect((bDuration - aDuration).abs(), lessThan(0.05));
  expect(wholeM4a(whole), isNull, reason: 'a whole file is left alone');
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('m4a-whole-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('pieces made by ffmpeg come out as one file with the same sound', () async {
    final frag = '${tmp.path}/frag.m4a';
    final made = await Process.run('ffmpeg', [
      '-v', 'error', '-y', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=7',
      '-c:a', 'aac', '-b:a', '128k',
      '-movflags', '+frag_keyframe+empty_moov+default_base_moof',
      '-frag_duration', '1500000', '-f', 'mp4', frag,
    ]);
    expect(made.exitCode, 0, reason: '${made.stderr}');
    await _same(frag, tmp);
  }, skip: !_ffmpeg);

  test('a real YouTube file, when one is given', () async {
    await _same(Platform.environment['WETOWL_M4A_SAMPLE']!, tmp);
  }, skip: !_ffmpeg || Platform.environment['WETOWL_M4A_SAMPLE'] == null);

  test('not an m4a, or a broken one, is left alone', () {
    expect(wholeM4a(Uint8List.fromList(List.filled(100, 7))), isNull);
    final lies = Uint8List(16)
      ..buffer.asByteData().setUint32(0, 9999)
      ..setRange(4, 8, 'moov'.codeUnits);
    expect(wholeM4a(lies), isNull);
  });
}
