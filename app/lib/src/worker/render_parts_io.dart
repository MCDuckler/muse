import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'separate.dart';
import 'separation_kit.dart';
import 'tools.dart';

/// Taking records apart on this computer, for this computer's booth.
///
/// The server can do this too and does it for everybody — see `server/muse/stems.py`
/// — but it is one small box doing one record at a time while also serving the music,
/// and a desk is not. Measured on the same machine, the arithmetic here finishes a
/// four minute record in about five seconds against the box's twelve, and that is
/// before a real desk's cores are counted. So where there is a computer to do it, it
/// is done here and the booth never waits for the network at all.
///
/// Kept beside the app rather than in the music library: these are workings, not
/// records, and nobody wants them turning up in their folders. Named by the track
/// rather than by the file's hash, which is how the server names its own — a client
/// is never told the hash, and a track number is as stable as anything it does know.
/// (Re-ingesting a record at better quality would leave its parts behind as stale;
/// rare enough to live with, and curable by clearing them.)

/// Bumped when what comes out changes. 2 is the trained separator
/// (separation_kit.dart); 1 is the arithmetic in separate.dart, which is still what
/// is made where the separator cannot run, and is kept apart by its number so a
/// computer that gets the separator later makes the better parts rather than keeping
/// the old ones.
const partsVersion = 2;
const _arithmeticVersion = 1;

/// Where the separator's files are fetched from: the house this app talks to. Set by
/// the booth (PartsStore); until it is, the separator is not tried.
String Function()? separationHouse;

/// The longest record that gets taken apart. The server's UP_TO_S: a set is not a
/// record, and a part that runs out before the record does is silence on a deck.
const upToSeconds = 12 * 60;

/// Only on a desk. A phone could run the arithmetic but should not: it is minutes of
/// every core it has, and the battery belongs to the person holding it.
bool get canSeparateHere =>
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// How a record is taken apart here. Swapped out in the tests, which have no ffmpeg
/// and no wish to wait five seconds for arithmetic that is checked elsewhere.
@visibleForTesting
typedef Renderer = Future<void> Function(
    String audio, String name, Map<String, String> into);

/// Forget what is in hand and what was given up on — between tests, where one
/// track number is reused by the next and this is the only state that outlives it.
@visibleForTesting
void forgetHere() {
  _making.clear();
  _cannot.clear();
  _separatorOff = null;
  _separatorFailed.clear();
  _progress.clear();
}

/// Whether the trained separator is out of the question on this computer, for as long
/// as the app is open: no program in the box, no house to fetch its files from, or it
/// was tried and failed. Null until somebody asks. Forgotten on restart, which is the
/// right moment to try again.
bool? _separatorOff;

@visibleForTesting
set separatorOffForTesting(bool? off) => _separatorOff = off;

/// Records the separator was run on and could not take apart — made the old way
/// instead, and not handed to the separator again until the app is next started.
final _separatorFailed = <int>{};

/// How far through each record being made here is, 0 to 1, by track.
final _progress = <int, double>{};

/// How far through taking [trackId] apart this computer is, while it is.
double? progressHere(int trackId) => _progress[trackId];

/// The real one, so a test that swapped it can put it back.
@visibleForTesting
const Renderer defaultRenderer = _render;

@visibleForTesting
Renderer renderer = defaultRenderer;

Directory? _dir;

/// Where the parts live: beside the app, not in the music.
Future<String> partsDir() async {
  if (_dir != null) return _dir!.path;
  final base = await getApplicationSupportDirectory();
  final d = Directory('${base.path}${Platform.pathSeparator}stems');
  await d.create(recursive: true);
  _dir = d;
  return d.path;
}

@visibleForTesting
set partsDirForTesting(String path) => _dir = Directory(path);

File partFile(Directory dir, int trackId, String name, {int version = partsVersion}) =>
    File('${dir.path}${Platform.pathSeparator}$trackId-$name-v$version.m4a');

Future<bool> _separatorPossible() async {
  if (_separatorOff != null) return !_separatorOff!;
  final possible = separationHouse != null &&
      runtimeFile != null &&
      await separatorProgram() != null;
  if (!possible) _separatorOff = true;
  return possible;
}

/// What this computer can say about a part of a record.
enum Here {
  /// Made, and on this disk.
  ready,

  /// Being made here. A few seconds.
  making,

  /// Not something this computer is going to manage — no ffmpeg, a record it could
  /// not read, or simply not a desk. Ask the house instead.
  cannot,
}

/// What is being made here, so three asks do not start three renders.
final _making = <String>{};

/// What this computer tried and could not do, so it does not keep trying and keep
/// saying "in a minute" about a part that is never coming. Forgotten on restart,
/// which is the right moment to find out that ffmpeg has been installed since.
final _cannot = <String>{};

/// One at a time. Separating is every core this machine will give it for a few
/// seconds; two at once is not twice as fast and does make the booth stutter.
Future<void> _bench = Future.value();

bool makingHere(int trackId, String name) => _making.contains('$trackId-$name');

/// The part of [audio] called [name], made here if it is not already.
///
/// Says which of the three things is true, and where the file is when there is one.
/// A [Here.cannot] is the important answer: it is what sends the asking to the
/// server rather than leaving a deck promising a part that will never arrive.
Future<(Here, String?)> partHere(String audio, int trackId, String name,
    {int? durationMs}) async {
  if (!canSeparateHere) return (Here.cannot, null);
  if (durationMs != null && durationMs > upToSeconds * 1000) return (Here.cannot, null);
  final dir = Directory(await partsDir());
  final want = partFile(dir, trackId, name);
  if (await want.exists()) return (Here.ready, want.path);
  if (_making.contains('$trackId-$name')) return (Here.making, null);
  final trained = await _separatorPossible() && !_separatorFailed.contains(trackId);
  if (!trained) {
    final older = partFile(dir, trackId, name, version: _arithmeticVersion);
    if (await older.exists()) return (Here.ready, older.path);
  }
  if (_cannot.contains('$trackId-$name')) return (Here.cannot, null);

  // Whatever one pass gives, so no part is queued twice: the separator makes all
  // three at once; the arithmetic makes the voice-less record on its own and the
  // drums and the music together.
  final together = trained
      ? partNames
      : name == 'instrumental'
          ? ['instrumental']
          : ['drums', 'music'];
  _making.addAll([for (final p in together) '$trackId-$p']);

  final mine = Completer<void>();
  final before = _bench;
  _bench = mine.future;
  unawaited(() async {
    try {
      await before;
      await renderer(audio, name, {
        for (final p in together)
          p: partFile(dir, trackId, p,
                  version: trained ? partsVersion : _arithmeticVersion)
              .path,
      });
    } catch (e) {
      debugPrint('could not take track $trackId apart here: $e');
      _cannot.addAll([for (final p in together) '$trackId-$p']);
    } finally {
      _making.removeAll([for (final p in together) '$trackId-$p']);
      _progress.remove(trackId);
      mine.complete();
    }
  }());
  return (Here.making, null);
}

// ------------------------------------------------------------------ the doing of it
/// The separator when [into] asks for its version, and the arithmetic when that is all
/// there is — or when the separator fails, which puts it out of the question until the
/// app is next started and makes the arithmetic's parts instead, so a record still
/// comes apart one way or the other.
Future<void> _render(String audio, String name, Map<String, String> into) async {
  final tools = await Tools.find(own: await _toolsDir());
  final ffmpeg = tools.ffmpeg;
  if (ffmpeg == null) throw StateError('no ffmpeg on this computer');

  final trained = into.values.every((f) => f.endsWith('-v$partsVersion.m4a'));
  if (trained) {
    final trackId = int.tryParse(
        into.values.first.split(Platform.pathSeparator).last.split('-').first);
    // Two ways to fail, and they mean different things. Not being able to set the
    // separator up — no program, no house, a fetch that failed or a file that was not
    // the right one — is true of every record, so it is not tried again until the app
    // is next started. A record it could not take apart is true of that record only.
    Separator? s;
    try {
      final house = separationHouse?.call();
      if (house == null || house.isEmpty) throw StateError('no house to fetch it from');
      s = await readySeparator(house);
      if (s == null) throw StateError('no separator for this computer');
    } catch (e) {
      debugPrint('no separator on this computer this time, so the arithmetic: $e');
      _separatorOff = true;
    }
    if (s != null) {
      try {
        await runSeparator(s,
            ffmpeg: ffmpeg,
            audio: audio,
            into: into,
            upToSeconds: upToSeconds,
            progress: (f) {
              if (trackId != null) _progress[trackId] = f;
            });
        return;
      } catch (e) {
        debugPrint('the separator could not take this one apart, so the arithmetic: $e');
        if (trackId != null) _separatorFailed.add(trackId);
      }
    }
    // The pair that was asked for, the old way.
    final dir = File(into.values.first).parent;
    final together = name == 'instrumental' ? ['instrumental'] : ['drums', 'music'];
    into = {
      for (final p in together)
        if (trackId != null)
          p: partFile(dir, trackId, p, version: _arithmeticVersion).path,
    };
    if (into.isEmpty) throw StateError('could not tell which record that was');
  }

  final decoded = await Process.run(
    ffmpeg,
    ['-v', 'error', '-t', '$upToSeconds', '-i', audio,
      '-ac', '2', '-ar', '$rate', '-f', 'f32le', '-'],
    stdoutEncoding: null,
    stderrEncoding: null,
  );
  if (decoded.exitCode != 0) throw StateError('ffmpeg could not read it');
  final raw = decoded.stdout as List<int>;
  final bytes = Uint8List.fromList(raw.sublist(0, raw.length ~/ 8 * 8));

  // Off the frame thread. A booth that stutters while it thinks is worse than one
  // that cannot take a record apart at all.
  //
  // Handed over rather than copied: a closure that captures the samples sends a copy
  // of them, and twelve minutes of stereo is a hundred and eighty megabytes to have
  // two of. Transferring empties this side's buffer, which is why nothing reads it
  // after this line.
  final moved = TransferableTypedData.fromList([bytes]);
  final parts = await Isolate.run(
      () => separate(moved.materialize().asFloat32List(), name));

  for (final e in parts.sound.entries) {
    final file = into[e.key];
    if (file == null) continue;
    await _encode(ffmpeg, e.value, parts.channels, File(file));
  }
}

Future<void> _encode(
    String ffmpeg, Float32List sound, int channels, File into) async {
  // Back off if the arithmetic pushed anything over: a part that clips is a part
  // nobody can use, and the booth matches levels anyway.
  var peak = 0.0;
  for (final v in sound) {
    final a = v.abs();
    if (a > peak) peak = a;
  }
  if (peak > 1.0) {
    for (var i = 0; i < sound.length; i++) {
      sound[i] = sound[i] / peak;
    }
  }
  // Still ending in .m4a: ffmpeg picks the format from the extension, and a file
  // called .tmp tells it nothing at all.
  final tmp = File(into.path.replaceFirst(RegExp(r'\.m4a$'), '.tmp.m4a'));
  final p = await Process.start(
    ffmpeg,
    ['-v', 'error', '-y', '-f', 'f32le', '-ar', '$rate', '-ac', '$channels',
      '-i', 'pipe:0', '-c:a', 'aac', '-b:a', '160k', tmp.path],
  );
  // Both pipes drained while stdin is written. A process whose output nobody is
  // reading fills its buffer and stops, and the write below then never finishes —
  // a deadlock that looks exactly like slow arithmetic.
  final said = <String>[];
  final watching = Future.wait([
    p.stderr.transform(const SystemEncoding().decoder).forEach(said.add),
    p.stdout.drain<void>(),
  ]);
  try {
    p.stdin.add(sound.buffer.asUint8List(0, sound.lengthInBytes));
    await p.stdin.flush();
  } on SocketException {
    // ffmpeg gave up early; its own words below say why.
  }
  await p.stdin.close();
  final code = await p.exitCode;
  await watching;
  if (code != 0) {
    if (await tmp.exists()) await tmp.delete();
    throw StateError('ffmpeg could not write the part: ${said.join().trim()}');
  }
  await tmp.rename(into.path);
}

/// The app's own tools folder, where somebody may have put an ffmpeg by hand. Asking
/// for it needs the app around it, so outside one this falls back to the PATH — which
/// is where it is on nearly every desk anyway.
Future<Directory?> _toolsDir() async {
  try {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}tools');
  } catch (_) {
    return null;
  }
}

/// Throw away what a run that did not finish left behind: the half-written file of a
/// render, and any record borrowed only to be taken apart. The server sweeps its own
/// for the same reason.
///
/// Only safe at startup. Nothing here is in use yet then, which is exactly what makes
/// a borrowed record safe to delete — a moment later it might be the thing being
/// separated.
Future<int> sweepHere() async {
  if (!canSeparateHere) return 0;
  var gone = 0;
  final dir = Directory(await partsDir());
  await for (final f in dir.list()) {
    final name = f.path.split(Platform.pathSeparator).last;
    if (f is File &&
        (name.endsWith('.tmp.m4a') ||
            name.startsWith('borrowed-') ||
            await _superseded(dir, name))) {
      try {
        await f.delete();
        gone++;
      } catch (_) {}
    }
  }
  // And any of the separator's files whose fetching was cut short.
  try {
    await for (final f in (await kitDir()).list()) {
      if (f is File && f.path.endsWith('.part')) {
        try {
          await f.delete();
          gone++;
        } catch (_) {}
      }
    }
  } catch (_) {}
  return gone;
}

/// An old part whose better twin has since been made: kept no longer.
Future<bool> _superseded(Directory dir, String name) async {
  final m = RegExp(r'^(\d+)-(\w+)-v' '$_arithmeticVersion' r'\.m4a$').firstMatch(name);
  if (m == null) return false;
  return partFile(dir, int.parse(m.group(1)!), m.group(2)!).exists();
}

/// Fetch a record this computer is not keeping, so it can be taken apart, and say
/// where it landed. Only once per record, however many of its parts are wanted.
Future<String?> borrowRecord(
    Uri from, Map<String, String> headers, int trackId) async {
  if (!canSeparateHere) return null;
  final dir = await partsDir();
  final into = File('$dir${Platform.pathSeparator}borrowed-$trackId.audio');
  if (await into.exists()) return into.path;
  final client = HttpClient();
  try {
    final request = await client.getUrl(from);
    headers.forEach(request.headers.set);
    final response = await request.close();
    if (response.statusCode >= 400) {
      throw StateError('the record could not be fetched (${response.statusCode})');
    }
    // Written beside itself and renamed when whole, so a record cut off halfway is
    // never mistaken for one that arrived. (The name still starts "borrowed-", so a
    // startup sweep clears it up if the app is closed mid-fetch.) This used to reuse
    // the parts' ".m4a → .tmp.m4a" line, which on a name ending ".audio" changed
    // nothing — the fetch went straight into the real name.
    final tmp = File('${into.path}.tmp');
    await response.pipe(tmp.openWrite());
    await tmp.rename(into.path);
    return into.path;
  } finally {
    client.close();
  }
}

/// Give back a record borrowed only to take apart. The parts themselves stay.
Future<void> giveBack(String path) async {
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
  } catch (_) {}
}
