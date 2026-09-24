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
//                   [--vocals <out>] [--bass-other <out>] [--stems <out.opus>]
//                   [--threads N] [--seconds N] [--raw] [--rate N] [--gpu cuda]
//   wetowl-separate --check-cuda
//
// With --gpu cuda (and --ort naming ONNX Runtime's CUDA build) the network runs on an
// NVIDIA card, about twelve times faster than on the processor — or, where the card's
// libraries will not load, on the processor as before. It says which on a
// "device cuda" / "device cpu: why" line. --check-cuda only asks whether the card's
// libraries (the driver, CUDA 13, cuDNN 9) can be loaded at all: "cuda ok", or
// "cuda missing <library>" and exit code 6 — so the app knows before it fetches
// ONNX Runtime's CUDA build, which is a few hundred megabytes.
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
    '[--seconds N] [--raw] [--rate N] [--gpu cuda] | --check-cuda';

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
  if (args.length == 1 && args.single == '--check-cuda') _checkCuda();
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
  // The three parts that add back up to the record, in one six-channel file: what a
  // deck plays to turn any of them up or down with no gap (see _stems).
  final stemsTo = opts['stems'];
  if (ort == null || model == null || ffmpeg == null || input == null ||
      (wanted.isEmpty && stemsTo == null)) {
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

  OrtNetwork load({required bool cuda}) => OrtNetwork.open(
        library: ort,
        model: model,
        inputName: 'spec',
        inputShape: specInShape,
        outputName: 'out',
        outputShape: specOutShape,
        threads: threads,
        cuda: cuda,
      );
  OrtNetwork net;
  try {
    net = load(cuda: opts['gpu'] == 'cuda');
  } catch (e) {
    _fail('could not load the model: $e', 3);
  }
  if (net.device == 'cuda') {
    // One piece of silence first. What the card's libraries cannot do — a cuDNN that
    // will not load, a card too old — shows up at the first run rather than when the
    // provider is added, and here it can still be the processor instead.
    try {
      net.input.fillRange(0, net.input.length, 0);
      net.run();
      stdout.writeln('device cuda');
    } catch (e) {
      net.close();
      stdout.writeln('device cpu: the card could not run it: $e');
      try {
        net = load(cuda: false);
      } catch (e) {
        _fail('could not load the model: $e', 3);
      }
    }
  } else {
    stdout.writeln(net.gpuProblem == null ? 'device cpu' : 'device cpu: ${net.gpuProblem}');
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
    final stems = stemsTo == null
        ? null
        : await _Writer.start(ffmpeg, stemsTo, raw: raw, rate: rate, stems: true);
    if (stems != null) writers['stems'] = stems;
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
        await e.value.add(e.key == 'stems' ? _stems(parts, n) : _mixed(parts, _recipes[e.key]!, n));
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

/// Whether the libraries ONNX Runtime's CUDA build needs will load here: the
/// driver's, CUDA 13's and cuDNN 9's, by the names that build asks for. Found the way
/// it will find them — the loader's own search, with the app having put the usual
/// places on the path.
Never _checkCuda() {
  final names = Platform.isWindows
      ? ['nvcuda.dll', 'cudart64_13.dll', 'cublas64_13.dll', 'cublasLt64_13.dll',
          'curand64_10.dll', 'cudnn64_9.dll']
      : ['libcuda.so.1', 'libcudart.so.13', 'libcublas.so.13', 'libcublasLt.so.13',
          'libcurand.so.10', 'libcudnn.so.9'];
  for (final n in names) {
    try {
      DynamicLibrary.open(n);
    } catch (_) {
      stdout.writeln('cuda missing $n');
      exit(6);
    }
  }
  stdout.writeln('cuda ok');
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

/// The stems file's six channels, interleaved: the drums (left, right), the bass and
/// everything else but the voice (left, right), the voice (left, right). Each kept
/// inside ±1 as a part is.
Float32List _stems(List<Float32List> parts, int n) {
  final pairs = [
    _mixed(parts, _recipes['drums']!, n),
    _mixed(parts, _recipes['bass-other']!, n),
    _mixed(parts, _recipes['vocals']!, n),
  ];
  final out = Float32List(n * 6);
  for (var i = 0; i < n; i++) {
    for (var p = 0; p < 3; p++) {
      out[i * 6 + p * 2] = pairs[p][i * 2];
      out[i * 6 + p * 2 + 1] = pairs[p][i * 2 + 1];
    }
  }
  return out;
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
      {required bool raw, required int rate, bool stems = false}) async {
    final dot = into.lastIndexOf('.');
    final slash = into.lastIndexOf(Platform.pathSeparator);
    // Still ending in the real extension: ffmpeg picks the format from it.
    final tmp = dot > slash
        ? '${into.substring(0, dot)}.tmp${into.substring(dot)}'
        : '$into.tmp';
    final p = await Process.start(ffmpeg, [
      '-v', 'error', '-nostdin', '-y',
      '-f', 'f32le', '-ar', '$modelRate', '-ac', stems ? '6' : '2', '-i', 'pipe:0',
      if (stems && !raw)
        // Opus, because its six channels are six channels: mapping family 255 has no
        // idea of a centre or a bass channel to low-pass or fold down. Always 48 kHz.
        ...['-ar', '48000', '-c:a', 'libopus', '-mapping_family', '255', '-b:a', '288k']
      else ...[
        '-ar', '$rate',
        if (raw) ...['-f', 'f32le'] else ...['-c:a', 'aac', '-b:a', '160k'],
      ],
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
