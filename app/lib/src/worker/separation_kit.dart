// The trained separator, from the app's side: where it is, fetching what it needs the
// first time, and running it.
//
// The program itself (wetowl-separate, bin/wetowl_separate.dart) comes in the box,
// beside wetowl-fetch. What it runs does not: the network is fifty-three megabytes and
// ONNX Runtime another sixteen to twenty-nine, which nobody who never opens the booth
// should download with every update. So both are fetched from the house the first time
// a record is taken apart, checked against the hashes below, and kept.
//
// Only this half touches files and processes; render_parts_io.dart decides when.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

/// Where the separator's own asides go: debugPrint in the app, the helper's log in
/// the windowless program. Nothing here may import Flutter — the windowless helper
/// (bin/wetowl_fetch.dart) takes records apart too.
void Function(String line) separatorSays = print;

/// One file the separator needs that does not come in the box.
@immutable
class KitFile {
  const KitFile(this.name, this.sha256, this.bytes);

  /// As kept here, and as served by the house under /models/ with ".gz" after it.
  final String name;

  /// Of the file itself, not the compressed download.
  final String sha256;
  final int bytes;
}

/// The network: SCNet Small, trained on MUSDB18 by its authors and published under
/// MIT; exported with tools/separation/export_scnet.py.
const modelFile = KitFile('scnet-small-v1.onnx',
    '678fb1f31846e1c0bab6602bdb2a9663dad85ad8adf2e5d9e29374d645c14367', 51352371);

/// The beat tracker: "Beat This!" (JKU Linz, ISMIR 2024, MIT), as exported to ONNX
/// (aaatmy/beat-this-onnx, checkpoint final0), and its frontend — the window and the
/// mel filters — beside it. Optional: a computer without them still splits records.
const beatModelFile = KitFile('beat-this-final0.onnx',
    'e5e37b7d1802895e42559c5a1ced7619b1601d257a5c8e167c9d45de37c1b078', 82098846);
const beatFrontendFile = KitFile('beat-this-frontend.json',
    '7b2ba71db92b79cb33f45feb21854161de329b86a7e6ea686c3fec51ce85eb9f', 298186);

/// ONNX Runtime 1.30.0 as Microsoft releases it (MIT), for the computers the
/// separator is built for. Anything else goes on with the old arithmetic.
KitFile? get runtimeFile => switch (Abi.current()) {
      Abi.linuxX64 => const KitFile('onnxruntime-1.30.0-linux-x64.so',
          '245a6f8c38127551057a1cd1ffd59f0a186a227ade4f3492dea2494eb565542e', 28985152),
      Abi.windowsX64 => const KitFile('onnxruntime-1.30.0-win-x64.dll',
          '7e39e2bdbba836d98071ef28620735ba36a47c554cf794585269aecc50fab0da', 16462648),
      _ => null,
    };

/// ONNX Runtime 1.30.0's CUDA 13 build, for an NVIDIA card: the runtime and the two
/// libraries it loads from beside itself, kept together in a folder of their own
/// under their own names — that is where and how it looks for them. About twelve
/// times the processor's speed on the network (measured: a four-minute record in 19 s
/// against 96 s, on a laptop RTX 4060), but a download of 150 to 235 MB, and it needs
/// the card's own libraries — the driver, CUDA 13 and cuDNN 9 — already on the
/// computer; the app never fetches those. See [cudaHere].
List<KitFile>? get cudaFiles => switch (Abi.current()) {
      Abi.linuxX64 => const [
          KitFile('onnxruntime-1.30.0-cuda13-linux-x64/libonnxruntime.so.1.30.0',
              '292591ed61befc515112570ae8eb9bb0d47716cd0ed60c38865800de4e829544', 32515904),
          KitFile('onnxruntime-1.30.0-cuda13-linux-x64/libonnxruntime_providers_shared.so',
              'c6a12593396095f5670160e284c35d1700b7708cf3037b7042e2a5200ccae772', 14632),
          KitFile('onnxruntime-1.30.0-cuda13-linux-x64/libonnxruntime_providers_cuda.so',
              '32fb1e28e5eafe8a39d52ca2e1e9c7333f3285968d288b43485cbaa32af6686e', 272054000),
        ],
      Abi.windowsX64 => const [
          KitFile('onnxruntime-1.30.0-cuda13-win-x64/onnxruntime.dll',
              'ed0de29f6579482eb2d54674a5e51b77761e195a5e0d70dbadc916ab925a9ec1', 16921400),
          KitFile('onnxruntime-1.30.0-cuda13-win-x64/onnxruntime_providers_shared.dll',
              '7ee69db9b57ce7279fd0a3b2c2ecb262de2509faeaf48de65a73415f9a0ca6f9', 21856),
          KitFile('onnxruntime-1.30.0-cuda13-win-x64/onnxruntime_providers_cuda.dll',
              '9b4e3abd26420845561c548d48adb80dde730e8d585b8f9c7a2d14cddc806eaa', 186986848),
        ],
      _ => null,
    };

/// Everything needed to run it, found and in place. [gpu]: on the graphics card.
/// [beatModel] and [beatFrontend] are the beat tracker's files, where they could be
/// had: null, and the parts come without beats.
typedef Separator = ({
  String program,
  String runtime,
  String model,
  bool gpu,
  String? beatModel,
  String? beatFrontend,
});

/// The program, where there is one: beside the app, as wetowl-fetch is. A build run
/// from the source tree has none there, so WETOWL_SEPARATE can name one.
String? _programForTesting;

@visibleForTesting
set separatorProgramForTesting(String? path) => _programForTesting = path;

Future<String?> separatorProgram() async {
  if (_programForTesting != null) return _programForTesting;
  final named = Platform.environment['WETOWL_SEPARATE'];
  if (named != null && named.isNotEmpty && await File(named).exists()) return named;
  final dir = File(Platform.resolvedExecutable).parent.path;
  final f = File('$dir${Platform.pathSeparator}'
      '${Platform.isWindows ? 'wetowl-separate.exe' : 'wetowl-separate'}');
  return await f.exists() ? f.path : null;
}

/// Where the fetched files are kept: `separation` in the app's own folder — which
/// the app and the windowless helper share.
Directory kitDirIn(Directory appFolder) =>
    Directory('${appFolder.path}${Platform.pathSeparator}separation');

/// The separator, fetching the network and the runtime from [house] if they are not
/// here yet. Null where there is no separator for this computer at all — no program
/// in the box, or a processor it is not built for — which is not a failure, just the
/// old arithmetic. Throws when the files could not be had.
/// [fetching] hears how a first-time fetch of either file is going.
///
/// On the graphics card where there is an NVIDIA card with its libraries on the
/// computer ([cudaHere]) and [gpu] is not turned off — fetching ONNX Runtime's CUDA
/// build for it the first time. Where that fetch fails, the processor, as before.
Future<Separator?> readySeparator(String house,
    {required Directory into,
    bool gpu = true,
    String? program,
    void Function(KitFile f, int got, int? total)? fetching}) async {
  program ??= await separatorProgram();
  final runtime = runtimeFile;
  if (program == null || runtime == null) return null;
  final dir = into;
  await dir.create(recursive: true);
  final model = await _have(modelFile, dir, house, fetching);
  // The beat tracker's files too, where the house has them: not a reason to fail a
  // split, which stands on its own without them.
  String? beatModel, beatFrontend;
  try {
    beatModel = await _have(beatModelFile, dir, house, fetching);
    beatFrontend = await _have(beatFrontendFile, dir, house, fetching);
  } catch (e) {
    separatorSays('separator: no beat tracker this time: $e');
    beatModel = beatFrontend = null;
  }
  final cuda = cudaFiles;
  if (gpu && cuda != null && await cudaHere(program)) {
    try {
      String? lib;
      for (final f in cuda) {
        final path = await _have(f, dir, house, fetching);
        lib ??= path;
      }
      return (
        program: program,
        runtime: lib!,
        model: model,
        gpu: true,
        beatModel: beatModel,
        beatFrontend: beatFrontend,
      );
    } catch (e) {
      separatorSays('separator: no CUDA runtime this time, so the processor: $e');
    }
  }
  final lib = await _have(runtime, dir, house, fetching);
  return (
    program: program,
    runtime: lib,
    model: model,
    gpu: false,
    beatModel: beatModel,
    beatFrontend: beatFrontend,
  );
}

/// Whether this computer can run the network on an NVIDIA card: the driver is there,
/// and the separator can load CUDA 13's and cuDNN 9's libraries (`--check-cuda`).
/// Asked once a run of the app. WETOWL_SEPARATE_GPU=0 says no without asking.
Future<bool> cudaHere(String program) => _cudaHere ??= () async {
      if (Platform.environment['WETOWL_SEPARATE_GPU'] == '0') return false;
      // No driver, no card worth asking about: not even the program is started.
      final driver = Platform.isWindows
          ? File('${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\nvcuda.dll')
          : File('/proc/driver/nvidia/version');
      if (!await driver.exists()) return false;
      try {
        final r = await Process.run(program, ['--check-cuda'], environment: _environment)
            .timeout(const Duration(seconds: 20));
        final said = '${r.stdout}'.trim();
        separatorSays('separator: $said');
        return r.exitCode == 0 && said == 'cuda ok';
      } catch (e) {
        separatorSays('separator: could not ask about the graphics card: $e');
        return false;
      }
    }();

Future<bool>? _cudaHere;

@visibleForTesting
void forgetCudaForTesting() => _cudaHere = null;

/// Whether the separator's files are both here already, so a split starts straight
/// away rather than with a fetch.
Future<bool> separatorFilesHere({required Directory into}) async {
  final runtime = runtimeFile;
  if (runtime == null) return false;
  final dir = into;
  for (final f in [modelFile, runtime]) {
    final file = File('${dir.path}${Platform.pathSeparator}${f.name}');
    if (!await file.exists() || await file.length() != f.bytes) return false;
  }
  return true;
}

/// Fetches in flight, so two records asking at once share one download.
final _fetching = <String, Future<String>>{};

Future<String> _have(KitFile f, Directory dir, String house,
    [void Function(KitFile f, int got, int? total)? fetching]) {
  final path = '${dir.path}${Platform.pathSeparator}${f.name}';
  return _fetching[path] ??= () async {
    try {
      final file = File(path);
      // Checked by size every time and by hash when it arrived: hashing fifty
      // megabytes before every record would be a second of nothing.
      if (await file.exists() && await file.length() == f.bytes) return path;
      await file.parent.create(recursive: true);
      await fetchKitFile(Uri.parse('$house/models/${f.name}.gz'), f, file,
          progress: fetching == null ? null : (got, total) => fetching(f, got, total));
      return path;
    } finally {
      _fetching.remove(path);
    }
  }();
}

/// Fetch [f] from [from] (gzipped) into [into], or throw and leave nothing behind.
/// Written beside itself and renamed only once the hash is right, so a file with the
/// real name is always the real file.
@visibleForTesting
Future<void> fetchKitFile(Uri from, KitFile f, File into,
    {void Function(int got, int? total)? progress}) async {
  final part = File('${into.path}.part');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(from);
    final response = await request.close();
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw HttpException('${f.name}: the house answered ${response.statusCode}', uri: from);
    }
    Digest? digest;
    final hashing = sha256.startChunkedConversion(
        ChunkedConversionSink<Digest>.withCallback((d) => digest = d.single));
    final sink = part.openWrite();
    var bytes = 0;
    // What has come over the wire, of what the house said it would send: the
    // compressed size, which is what a person is waiting for.
    var wire = 0;
    final length = response.contentLength >= 0 ? response.contentLength : null;
    try {
      await for (final chunk in response
          .timeout(const Duration(seconds: 60))
          .map((c) {
            wire += c.length;
            progress?.call(wire, length);
            return c;
          })
          .transform(gzip.decoder)) {
        bytes += chunk.length;
        if (bytes > f.bytes) throw StateError('${f.name}: longer than it should be');
        hashing.add(chunk);
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    hashing.close();
    if (bytes != f.bytes || digest.toString() != f.sha256) {
      throw StateError('${f.name}: not the file it should be ($bytes bytes, $digest)');
    }
    await part.rename(into.path);
  } catch (_) {
    if (await part.exists()) await part.delete();
    rethrow;
  } finally {
    client.close(force: true);
  }
}

/// How many threads to give it: a little under half the machine, and never more than
/// six. Past eight it is no faster (measured), and with the booth playing, the room it
/// leaves is the difference between two decks held on the beat and a glitch: on the
/// real engine, a split running beside a mix at eight threads cost one beat 140 ms.
int separatorThreads() => (Platform.numberOfProcessors ~/ 2 - 1).clamp(1, 6);

/// Take [audio] apart with [s], writing the parts named in [into] (part → file).
///
/// Behind everything else on the computer: under `nice` at its lowest where there is
/// one, and the program lowers itself on Windows. Killed if it has not finished in an hour, which
/// no record under the twelve-minute cap comes near.
Future<void> runSeparator(Separator s,
    {required String ffmpeg,
    required String audio,
    required Map<String, String> into,
    required int upToSeconds,
    String? beats,
    void Function(double)? progress,
    void Function(String device)? device,
    void Function(Process)? started}) async {
  final args = [
    '--ort', s.runtime,
    '--model', s.model,
    '--ffmpeg', ffmpeg,
    '--in', audio,
    '--seconds', '$upToSeconds',
    '--threads', '${separatorThreads()}',
    if (s.gpu) ...['--gpu', 'cuda'],
    for (final e in into.entries) ...['--${e.key}', e.value],
    // Its beats and bars too, where the tracker's files are here and they are wanted.
    if (beats != null && s.beatModel != null && s.beatFrontend != null)
      ...['--beats', beats, '--beats-model', s.beatModel!, '--beats-frontend', s.beatFrontend!],
  ];
  String? nice;
  if (!Platform.isWindows) {
    for (final n in ['/usr/bin/nice', '/bin/nice']) {
      if (await File(n).exists()) {
        nice = n;
        break;
      }
    }
  }
  final p = nice != null
      ? await Process.start(nice, ['-n', '19', s.program, ...args],
          environment: _environment)
      : await Process.start(s.program, args, environment: _environment);
  started?.call(p);
  final said = StringBuffer();
  final watching = Future.wait([
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach((line) {
      if (line.startsWith('progress ')) {
        final f = double.tryParse(line.substring(9));
        if (f != null) progress?.call(f);
      } else if (line.startsWith('device ')) {
        device?.call(line.substring(7));
      }
    }),
    p.stderr.transform(utf8.decoder).forEach(said.write),
  ]);
  final code = await p.exitCode.timeout(const Duration(hours: 1), onTimeout: () {
    p.kill();
    return -1;
  });
  await watching;
  if (code != 0) {
    throw StateError('the separator stopped ($code): ${said.toString().trim()}');
  }
}

/// On Linux, one malloc heap: see _oneHeapOnLinux in the program, which does the
/// same from inside but can only limit heaps not already made by then. And the places
/// the card's libraries are usually put, on the loader's path: CUDA's own installers
/// do not put them there, and ONNX Runtime asks for them by name.
final Map<String, String> _environment = () {
  final env = Platform.environment;
  if (Platform.isLinux) {
    final extra = ['/opt/cuda/lib64', '/usr/local/cuda/lib64', '/usr/lib/x86_64-linux-gnu']
        .where((d) => Directory(d).existsSync());
    final had = env['LD_LIBRARY_PATH'];
    return {
      'MALLOC_ARENA_MAX': '1',
      'LD_LIBRARY_PATH': [if (had != null && had.isNotEmpty) had, ...extra].join(':'),
    };
  }
  if (Platform.isWindows) {
    final dirs = <String>[];
    void add(String d) {
      if (Directory(d).existsSync()) dirs.add(d);
    }

    final cuda = env['CUDA_PATH'];
    if (cuda != null) {
      add('$cuda\\bin\\x64');
      add('$cuda\\bin');
    }
    // cuDNN's installer: C:\Program Files\NVIDIA\CUDNN\v9.x\bin\13.x[\x64].
    final cudnn = Directory('${env['ProgramFiles'] ?? r'C:\Program Files'}\\NVIDIA\\CUDNN');
    try {
      for (final v in cudnn.listSync().whereType<Directory>()) {
        final bin = Directory('${v.path}\\bin');
        if (!bin.existsSync()) continue;
        for (final c in bin.listSync().whereType<Directory>()) {
          if (!c.path.split('\\').last.startsWith('13')) continue;
          add('${c.path}\\x64');
          add(c.path);
        }
      }
    } catch (_) {}
    // The key is spelled however Windows spelled it; replace that one.
    final key = env.keys.firstWhere((k) => k.toUpperCase() == 'PATH', orElse: () => 'PATH');
    return {key: [...dirs, env[key] ?? ''].join(';')};
  }
  return const <String, String>{};
}();

/// One separator at a time on a computer, whoever starts it: the app's own splits, the
/// pool's, and the windowless helper's. Each wants every core (or the whole card), and
/// two at once is each at half speed and twice the memory.
///
/// A file lock in the app's own folder for the other program, and a chain here for
/// this one — a file lock is the process's, and would let two in from the same app.
Future<T> withSeparatorLock<T>(Directory appFolder, Future<T> Function() work) {
  final before = _separatorTurn;
  final mine = Completer<void>();
  _separatorTurn = mine.future;
  return () async {
    try {
      await before;
      await appFolder.create(recursive: true);
      final f = await File('${appFolder.path}${Platform.pathSeparator}separating.lock')
          .open(mode: FileMode.append);
      try {
        await f.lock(FileLock.blockingExclusive);
        return await work();
      } finally {
        try {
          await f.unlock();
        } catch (_) {}
        await f.close();
      }
    } finally {
      mine.complete();
    }
  }();
}

Future<void> _separatorTurn = Future.value();
