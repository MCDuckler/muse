// wetowl-separate: taking one record apart with the trained model, with no window.
//
// The booth plays parts of records — the drums, the music without them, the record
// without its voice. A trained network does that far better than the arithmetic the
// app used to do (tools/separation/README.md has the numbers), but it wants gigabytes
// and every core it can have for a minute or two a record. So it runs here, in a
// process of its own: the app starts it and waits, and if the machine runs short of
// memory it is this that goes, not the music playing.
//
//   wetowl-separate --ort <onnxruntime library> --model <scnet .onnx>
//                   --ffmpeg <ffmpeg> --in <record>
//                   [--instrumental <out>] [--drums <out>] [--music <out>]
//                   [--vocals <out>] [--bass-other <out>]
//                   [--threads N] [--seconds N] [--raw] [--rate N]
//
// Each output is written beside itself as <name>.tmp.<ext> and renamed when complete,
// so a file with the real name is always a whole one. Parts come out at 32 kHz, AAC
// in .m4a — the booth's format — or, with --raw, as bare 32-bit floats (for measuring;
// --rate 44100 then gives exactly what the model made, for comparing with the Python).
// While it works it prints "progress 0.42" lines; at the end, "done".
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:muse/src/separation/ort.dart';
import 'package:muse/src/separation/parallel.dart';
import 'package:muse/src/separation/scnet.dart';

const _usage = 'usage: wetowl-separate --ort <library> --model <model.onnx> '
    '--ffmpeg <ffmpeg> --in <record> [--instrumental <out>] [--drums <out>] '
    '[--music <out>] [--vocals <out>] [--bass-other <out>] [--threads N] '
    '[--seconds N] [--raw] [--rate N]';

/// What each part is made of, from the model's four: drums, bass, other, vocals.
const _recipes = {
  'instrumental': [0, 1, 2], // everything but the voice
  'drums': [0],
  'music': [1, 2, 3], // everything but the drums: what the booth has always called music
  'vocals': [3],
  'bass-other': [1, 2], // neither drums nor voice
};

/// The rate the parts are kept at — the booth's, and the server's.
const _partRate = 32000;

Future<void> main(List<String> args) async {
  final opts = <String, String>{};
  var raw = false;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--raw') {
      raw = true;
    } else if (a.startsWith('--') && i + 1 < args.length) {
      opts[a.substring(2)] = args[++i];
    } else {
      _fail('did not understand "$a"\n$_usage', 64);
    }
  }
  final ort = opts['ort'], model = opts['model'], ffmpeg = opts['ffmpeg'];
  final input = opts['in'];
  final wanted = {
    for (final p in _recipes.keys)
      if (opts[p] != null) p: opts[p]!,
  };
  if (ort == null || model == null || ffmpeg == null || input == null || wanted.isEmpty) {
    _fail(_usage, 64);
  }
  final threads = int.tryParse(opts['threads'] ?? '') ?? 4;
  final seconds = int.tryParse(opts['seconds'] ?? '') ?? 12 * 60;
  final rate = int.tryParse(opts['rate'] ?? '') ?? _partRate;

  // Behind whatever the person at the computer is doing, the music they are playing
  // most of all. On Linux and macOS the app starts this under `nice`; Windows has no
  // such program, so there it is done from inside.
  if (Platform.isWindows) _politeOnWindows();
  if (Platform.isLinux) _oneHeapOnLinux();

  final OrtNetwork net;
  try {
    net = OrtNetwork.open(
      library: ort,
      model: model,
      inputName: 'spec',
      inputShape: specInShape,
      outputName: 'out',
      outputShape: specOutShape,
      threads: threads,
    );
  } catch (e) {
    _fail('could not load the model: $e', 3);
  }

  final timing = Platform.environment['WETOWL_SEPARATE_TIMING'] != null;
  final clock = Stopwatch()..start();
  void mark(String what) {
    if (timing) stderr.writeln('timing: $what ${clock.elapsedMilliseconds} ms');
  }
  mark('model loaded');

  final Float32List stereo;
  try {
    stereo = await _decode(ffmpeg, input, seconds);
    mark('decoded');
  } catch (e) {
    net.close();
    _fail('$e', 4);
  }
  if (stereo.length < 2) {
    net.close();
    _fail('there is no sound in that file', 4);
  }

  final writers = <String, _Writer>{};
  try {
    for (final e in wanted.entries) {
      writers[e.key] = await _Writer.start(ffmpeg, e.value, raw: raw, rate: rate);
    }
    final sound = SharedSound();
    final piece = await ParallelPiece.start(
      network: net.run,
      specIn: net.inputPointer,
      specOut: net.outputPointer,
      sound: sound,
      helpers: threads,
    );
    var said = -1;
    await demix(stereo, piece, left: sound.left, right: sound.right, out: sound.out,
        (from, n, parts) async {
      for (final e in writers.entries) {
        await e.value.add(_mixed(parts, _recipes[e.key]!, n));
      }
    }, progress: (f) {
      final pct = (f * 100).floor();
      if (pct != said) {
        said = pct;
        stdout.writeln('progress ${f.toStringAsFixed(3)}');
      }
    });
    mark('separated');
    if (timing) {
      stderr.writeln('timing: in ${piece.inWatch.elapsedMilliseconds} ms, network '
          '${piece.netWatch.elapsedMilliseconds} ms, out ${piece.outWatch.elapsedMilliseconds} ms');
    }
    piece.close();
    sound.free();
    for (final w in writers.values) {
      await w.finish();
    }
    mark('written');
  } catch (e) {
    for (final w in writers.values) {
      await w.abandon();
    }
    net.close();
    _fail('$e', 5);
  }
  net.close();
  stdout.writeln('done');
  await stdout.flush();
  exit(0);
}

Never _fail(String why, int code) {
  stderr.writeln('wetowl-separate: $why');
  exit(code);
}

/// The record as interleaved stereo floats at the model's rate. ffmpeg does the
/// reading and the resampling, as it does everywhere else in the app.
Future<Float32List> _decode(String ffmpeg, String input, int seconds) async {
  final p = await Process.start(ffmpeg, [
    '-v', 'error', '-nostdin', '-t', '$seconds', '-i', input,
    '-ac', '2', '-ar', '$modelRate', '-f', 'f32le', '-',
  ]);
  final got = BytesBuilder(copy: false);
  final said = <int>[];
  await Future.wait([
    p.stdout.forEach(got.add),
    p.stderr.forEach(said.addAll),
  ]);
  final code = await p.exitCode;
  if (code != 0) {
    throw StateError('ffmpeg could not read it: ${String.fromCharCodes(said).trim()}');
  }
  final bytes = got.takeBytes();
  final whole = bytes.length ~/ 8 * 8;
  return bytes.buffer.asFloat32List(bytes.offsetInBytes, whole ~/ 4);
}

/// One part, from the model's eight signals, interleaved stereo and kept inside ±1: a
/// part that clips is a part nobody can use.
Float32List _mixed(List<Float32List> parts, List<int> sources, int n) {
  final out = Float32List(n * 2);
  for (var c = 0; c < 2; c++) {
    for (final s in sources) {
      final from = parts[s * 2 + c];
      for (var i = 0; i < n; i++) {
        out[i * 2 + c] += from[i];
      }
    }
  }
  for (var i = 0; i < out.length; i++) {
    final v = out[i];
    if (v > 1) {
      out[i] = 1;
    } else if (v < -1) {
      out[i] = -1;
    }
  }
  return out;
}

/// An ffmpeg turning one part's floats into a file as they arrive.
class _Writer {
  _Writer._(this._p, this._tmp, this._into, this._said, this._watching);

  static Future<_Writer> start(String ffmpeg, String into,
      {required bool raw, required int rate}) async {
    final dot = into.lastIndexOf('.');
    final slash = into.lastIndexOf(Platform.pathSeparator);
    // Still ending in the real extension: ffmpeg picks the format from it.
    final tmp = dot > slash
        ? '${into.substring(0, dot)}.tmp${into.substring(dot)}'
        : '$into.tmp';
    final p = await Process.start(ffmpeg, [
      '-v', 'error', '-nostdin', '-y',
      '-f', 'f32le', '-ar', '$modelRate', '-ac', '2', '-i', 'pipe:0',
      '-ar', '$rate',
      if (raw) ...['-f', 'f32le'] else ...['-c:a', 'aac', '-b:a', '160k'],
      tmp,
    ]);
    // Both pipes drained while stdin is written: a process whose output nobody reads
    // fills its buffer and stops, and the writing then never finishes.
    final said = <int>[];
    final watching = Future.wait([p.stderr.forEach(said.addAll), p.stdout.drain<void>()]);
    return _Writer._(p, File(tmp), into, said, watching);
  }

  final Process _p;
  final File _tmp;
  final String _into;
  final List<int> _said;
  final Future<void> _watching;

  Future<void> add(Float32List samples) async {
    _p.stdin.add(samples.buffer.asUint8List(samples.offsetInBytes, samples.lengthInBytes));
    await _p.stdin.flush();
  }

  Future<void> finish() async {
    await _p.stdin.close();
    final code = await _p.exitCode;
    await _watching;
    if (code != 0) {
      if (await _tmp.exists()) await _tmp.delete();
      throw StateError('ffmpeg could not write $_into: ${String.fromCharCodes(_said).trim()}');
    }
    await _tmp.rename(_into);
  }

  Future<void> abandon() async {
    _p.kill();
    try {
      await _p.exitCode.timeout(const Duration(seconds: 5));
      if (await _tmp.exists()) await _tmp.delete();
    } catch (_) {}
  }
}

/// One malloc heap for the whole process, before ONNX Runtime starts.
///
/// glibc gives every thread that allocates a heap of its own and keeps what is freed
/// in it for later. Dart moves this program between threads whenever it waits, so the
/// network's working memory landed in a fresh heap nearly every piece and was never
/// given back: measured, 1.5 GB at the start of a four minute record and 7 GB by the
/// end. With one heap it stays at 1.5 GB throughout, and is no slower.
void _oneHeapOnLinux() {
  try {
    final mallopt = DynamicLibrary.process()
        .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('mallopt');
    const arenaMax = -8; // M_ARENA_MAX
    mallopt(arenaMax, 1);
  } catch (_) {
    // Not glibc (musl, say): its allocator does not do this in the first place.
  }
}

/// Below normal priority, for the whole process. Windows' own call; see main.
void _politeOnWindows() {
  try {
    final k = DynamicLibrary.open('kernel32.dll');
    final current =
        k.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('GetCurrentProcess');
    final setPriority = k.lookupFunction<Int32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)>('SetPriorityClass');
    const belowNormal = 0x00004000;
    setPriority(current(), belowNormal);
  } catch (_) {
    // Not fatal: it only means the booth has to share.
  }
}
