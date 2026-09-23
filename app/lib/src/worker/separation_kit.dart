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
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

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

/// ONNX Runtime 1.30.0 as Microsoft releases it (MIT), for the computers the
/// separator is built for. Anything else goes on with the old arithmetic.
KitFile? get runtimeFile => switch (Abi.current()) {
      Abi.linuxX64 => const KitFile('onnxruntime-1.30.0-linux-x64.so',
          '245a6f8c38127551057a1cd1ffd59f0a186a227ade4f3492dea2494eb565542e', 28985152),
      Abi.windowsX64 => const KitFile('onnxruntime-1.30.0-win-x64.dll',
          '7e39e2bdbba836d98071ef28620735ba36a47c554cf794585269aecc50fab0da', 16462648),
      _ => null,
    };

/// Everything needed to run it, found and in place.
typedef Separator = ({String program, String runtime, String model});

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

Directory? _kitDir;

@visibleForTesting
set kitDirForTesting(String? path) => _kitDir = path == null ? null : Directory(path);

/// Where the fetched files are kept: beside the app's other workings.
Future<Directory> kitDir() async {
  if (_kitDir != null) return _kitDir!;
  final base = await getApplicationSupportDirectory();
  final d = Directory('${base.path}${Platform.pathSeparator}separation');
  await d.create(recursive: true);
  return d;
}

/// The separator, fetching the network and the runtime from [house] if they are not
/// here yet. Null where there is no separator for this computer at all — no program
/// in the box, or a processor it is not built for — which is not a failure, just the
/// old arithmetic. Throws when the files could not be had.
Future<Separator?> readySeparator(String house, {Directory? into}) async {
  final program = await separatorProgram();
  final runtime = runtimeFile;
  if (program == null || runtime == null) return null;
  final dir = into ?? await kitDir();
  final model = await _have(modelFile, dir, house);
  final lib = await _have(runtime, dir, house);
  return (program: program, runtime: lib, model: model);
}

/// Fetches in flight, so two records asking at once share one download.
final _fetching = <String, Future<String>>{};

Future<String> _have(KitFile f, Directory dir, String house) {
  final path = '${dir.path}${Platform.pathSeparator}${f.name}';
  return _fetching[path] ??= () async {
    try {
      final file = File(path);
      // Checked by size every time and by hash when it arrived: hashing fifty
      // megabytes before every record would be a second of nothing.
      if (await file.exists() && await file.length() == f.bytes) return path;
      await fetchKitFile(Uri.parse('$house/models/${f.name}.gz'), f, file);
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
Future<void> fetchKitFile(Uri from, KitFile f, File into) async {
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
    try {
      await for (final chunk in response
          .timeout(const Duration(seconds: 60))
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

/// How many threads to give it: half the machine, and never more than eight — past
/// that it is no faster (measured) and the music playing has less room.
int separatorThreads() => (Platform.numberOfProcessors ~/ 2).clamp(1, 8);

/// Take [audio] apart with [s], writing the parts named in [into] (part → file).
///
/// Behind everything else on the computer: under `nice` where there is one, and the
/// program lowers itself on Windows. Killed if it has not finished in an hour, which
/// no record under the twelve-minute cap comes near.
Future<void> runSeparator(Separator s,
    {required String ffmpeg,
    required String audio,
    required Map<String, String> into,
    required int upToSeconds,
    void Function(double)? progress}) async {
  final args = [
    '--ort', s.runtime,
    '--model', s.model,
    '--ffmpeg', ffmpeg,
    '--in', audio,
    '--seconds', '$upToSeconds',
    '--threads', '${separatorThreads()}',
    for (final e in into.entries) ...['--${e.key}', e.value],
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
      ? await Process.start(nice, ['-n', '10', s.program, ...args],
          environment: _environment)
      : await Process.start(s.program, args, environment: _environment);
  final said = StringBuffer();
  final watching = Future.wait([
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach((line) {
      if (line.startsWith('progress ')) {
        final f = double.tryParse(line.substring(9));
        if (f != null) progress?.call(f);
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
/// same from inside but can only limit heaps not already made by then.
final _environment = {if (Platform.isLinux) 'MALLOC_ARENA_MAX': '1'};
