import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../api/models.dart';
import 'parts_jobs.dart';
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

/// What the trained separator makes, all in one pass: the record without its voice,
/// the drums, everything but the drums, and the voice on its own.
const trainedParts = ['instrumental', 'drums', 'music', 'vocals'];

/// What the house makes, and what the arithmetic here makes. The voice on its own is
/// not one of them: lifting it out cleanly is exactly what the arithmetic cannot do.
const serverParts = {'instrumental', 'drums', 'music'};

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
  _generation++;
  _making.clear();
  _cannot.clear();
  _cancelled.clear();
  _separatorOff = null;
  _separatorFailed.clear();
  _line.clear();
  _now = null;
  _running = null;
  _stop = null;
  partsJobs.forget();
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

/// Records somebody took off the list. Not queued again this session unless a part
/// of one is asked for by hand: the automix asks three records ahead, and would
/// otherwise put straight back what was just cancelled.
final _cancelled = <int>{};

bool cancelledHere(int trackId) => _cancelled.contains(trackId);

/// Forget that [trackId] failed or was cancelled, so that asking again tries again —
/// the Retry button, or a part asked for by hand.
void forgiveHere(int trackId) {
  _cancelled.remove(trackId);
  _separatorFailed.remove(trackId);
  _cannot.removeWhere((k) => k.startsWith('$trackId-'));
  // A separator that could not be set up — a fetch that failed — gets another go as
  // well. One that is simply not in the box is found not to be again, at no cost.
  _separatorOff = null;
}

/// Whether [name] of [trackId] is something this computer could make at all, before
/// anything is fetched to make it: the voice on its own needs the separator.
Future<bool> canMakeHere(int trackId, String name) async {
  if (!canSeparateHere) return false;
  if (serverParts.contains(name)) return true;
  return await _separatorPossible() && !_separatorFailed.contains(trackId);
}

/// A record waiting to be taken apart, and everything needed to do it.
class _Render {
  _Render(this.trackId, this.audio, this.name, this.into, this.together, this.trained);
  final int trackId;
  final String audio, name;

  /// Part → the file it goes in.
  final Map<String, String> into;
  final List<String> together;
  final bool trained;
}

/// The line, and the one being taken apart now. One at a time: separating is every
/// core this machine will give it, and two at once is not twice as fast — it is the
/// booth stuttering.
final _line = <_Render>[];
_Render? _now;

/// Bumped when everything is forgotten, so a run still finishing from before — a test's,
/// say — does not reach into the line that replaced it.
int _generation = 0;

/// The separator while it runs, so a cancel can stop it.
Process? _running;

/// Completed when the one in hand is cancelled.
Completer<void>? _stop;

class _Cancelled implements Exception {
  const _Cancelled();
  @override
  String toString() => 'cancelled';
}

/// [work], unless the one in hand is cancelled first — then it is let go of where it
/// is. What cannot be stopped (the arithmetic's isolate, a fetch shared with others)
/// finishes in the background and is thrown away.
Future<T> _unlessCancelled<T>(Future<T> work) {
  final stop = _stop;
  if (stop == null) return work;
  return Future.any([work, stop.future.then<T>((_) => throw const _Cancelled())]);
}

bool makingHere(int trackId, String name) => _making.contains('$trackId-$name');

/// The file of [name] for [trackId] if it has been made here, without needing the
/// record at all: what saves fetching eight megabytes to be told it was done last week.
/// The separator's first; the arithmetic's where the separator is out of the question.
Future<String?> partReady(int trackId, String name) async {
  if (!canSeparateHere) return null;
  final dir = Directory(await partsDir());
  final want = partFile(dir, trackId, name);
  if (await want.exists()) return want.path;
  if (await _separatorPossible() && !_separatorFailed.contains(trackId)) return null;
  final older = partFile(dir, trackId, name, version: _arithmeticVersion);
  return await older.exists() ? older.path : null;
}

/// Take [trackId] off the list, wherever it is: waiting, having its record fetched, or
/// being taken apart — which is stopped.
void cancelHere(int trackId) {
  _cancelled.add(trackId);
  for (final r in _line.where((r) => r.trackId == trackId).toList()) {
    _line.remove(r);
    _making.removeAll([for (final p in r.together) '$trackId-$p']);
  }
  if (_now?.trackId == trackId) {
    final stop = _stop;
    if (stop != null && !stop.isCompleted) stop.complete();
    _running?.kill();
  }
  final j = partsJobs.of(trackId);
  if (j != null && !j.done) partsJobs.stage(trackId, PartsStage.cancelled);
}

/// Put [trackId] first among the waiting: somebody wants it now.
void promoteHere(int trackId) {
  if (partsJobs.of(trackId)?.stage == PartsStage.waiting) partsJobs.first(trackId);
}

/// The part of [audio] called [name], made here if it is not already.
///
/// Says which of the three things is true, and where the file is when there is one.
/// A [Here.cannot] is the important answer: it is what sends the asking to the
/// server rather than leaving a deck promising a part that will never arrive.
/// [track] names the job in the list the booth and the downloads page show.
Future<(Here, String?)> partHere(String audio, int trackId, String name,
    {int? durationMs, Track? track}) async {
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
    if (!serverParts.contains(name)) return (Here.cannot, null);
  }
  if (_cannot.contains('$trackId-$name') || _cancelled.contains(trackId)) {
    return (Here.cannot, null);
  }

  // Whatever one pass gives, so no part is queued twice: the separator makes all four
  // at once — those not made already — and the arithmetic makes the voice-less record
  // on its own and the drums and the music together.
  final together = trained
      ? [
          for (final p in trainedParts)
            if (p == name || !await partFile(dir, trackId, p).exists()) p,
        ]
      : name == 'instrumental'
          ? ['instrumental']
          : ['drums', 'music'];
  _making.addAll([for (final p in together) '$trackId-$p']);
  _line.add(_Render(
    trackId,
    audio,
    name,
    {
      for (final p in together)
        p: partFile(dir, trackId, p, version: trained ? partsVersion : _arithmeticVersion).path,
    },
    together,
    trained,
  ));
  partsJobs.add(trackId, track: track, parts: together, trained: trained);
  // Into the line — unless this record is the one being taken apart right now, and
  // this is a second pass of the arithmetic's waiting behind it.
  if (_now?.trackId != trackId) partsJobs.stage(trackId, PartsStage.waiting, trained: trained);
  unawaited(_pump());
  return (Here.making, null);
}

/// Work down the line, one at a time, in the order the list shows: somebody may have
/// put one first.
Future<void> _pump() async {
  if (_now != null) return;
  final gen = _generation;
  bool live() => gen == _generation;
  while (_line.isNotEmpty && live()) {
    final order = [for (final j in partsJobs.waiting) j.trackId];
    var r = _line.first;
    var best = order.length;
    for (final c in _line) {
      final i = order.indexOf(c.trackId);
      if (i >= 0 && i < best) {
        best = i;
        r = c;
      }
    }
    _line.remove(r);
    _now = r;
    final stop = _stop = Completer<void>();
    final id = r.trackId;
    try {
      partsJobs.stage(id, PartsStage.separating, trained: r.trained);
      await _unlessCancelled(renderer(r.audio, r.name, r.into));
      if (stop.isCompleted) throw const _Cancelled();
      if (!live()) return;
      // The arithmetic can have a second pass of the same record behind this one.
      partsJobs.stage(
          id, _line.any((x) => x.trackId == id) ? PartsStage.waiting : PartsStage.ready);
    } catch (e) {
      if (!live()) return;
      if (e is _Cancelled || stop.isCompleted) {
        await _tidyAfter(r);
        final j = partsJobs.of(id);
        if (j != null && !j.done) partsJobs.stage(id, PartsStage.cancelled);
      } else {
        debugPrint('could not take track $id apart here: $e');
        _cannot.addAll([for (final p in r.together) '$id-$p']);
        partsJobs.stage(id, PartsStage.failed, error: _short(e));
      }
    } finally {
      if (live()) {
        _making.removeAll([for (final p in r.together) '$id-$p']);
        _now = null;
        _stop = null;
      }
    }
  }
}

/// What a stopped run leaves: its half-written files, once the separator has gone.
Future<void> _tidyAfter(_Render r) async {
  try {
    await _running?.exitCode.timeout(const Duration(seconds: 5));
  } catch (_) {}
  for (final f in r.into.values) {
    final tmp = File(f.replaceFirst(RegExp(r'\.m4a$'), '.tmp.m4a'));
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
  }
}

/// A failure in a few words, for a row.
String _short(Object e) {
  var s = '$e'.replaceFirst(RegExp(r'^(Bad state|Exception|StateError|HttpException): '), '');
  s = s.split('\n').first.trim();
  return s.length > 90 ? '${s.substring(0, 89)}…' : s;
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

  // This run's own stop, held on to: a cancelled run finishing in the background must
  // not read the next one's.
  final stop = _stop;
  bool stopped() => stop?.isCompleted ?? false;
  final trackId = int.tryParse(
      into.values.first.split(Platform.pathSeparator).last.split('-').first);

  final trained = into.values.every((f) => f.endsWith('-v$partsVersion.m4a'));
  if (trained) {
    // Two ways to fail, and they mean different things. Not being able to set the
    // separator up — no program, no house, a fetch that failed or a file that was not
    // the right one — is true of every record, so it is not tried again until the app
    // is next started. A record it could not take apart is true of that record only.
    Separator? s;
    try {
      final house = separationHouse?.call();
      if (house == null || house.isEmpty) throw StateError('no house to fetch it from');
      // The first time, the separator's own files come first: a stage of its own, since
      // it is eighty megabytes nobody asked for by name.
      var fetching = false;
      s = await _unlessCancelled(readySeparator(house, fetching: (f, got, total) {
        if (trackId == null || stopped()) return;
        if (!fetching) {
          fetching = true;
          partsJobs.stage(trackId, PartsStage.gettingSeparator);
        }
        partsJobs.progress(trackId, total == null ? null : got / total,
            bytes: got, total: total);
      }));
      if (fetching && trackId != null) {
        partsJobs.stage(trackId, PartsStage.separating, trained: true);
      }
      if (s == null) throw StateError('no separator for this computer');
    } on _Cancelled {
      rethrow;
    } catch (e) {
      debugPrint('no separator on this computer this time, so the arithmetic: $e');
      _separatorOff = true;
    }
    if (s != null) {
      Process? mine;
      try {
        await runSeparator(s,
            ffmpeg: ffmpeg,
            audio: audio,
            into: into,
            upToSeconds: upToSeconds,
            progress: (f) {
              if (trackId != null && !stopped()) partsJobs.progress(trackId, f);
            },
            started: (p) {
              mine = p;
              _running = p;
              if (stopped()) p.kill();
            });
        return;
      } catch (e) {
        if (stopped()) throw const _Cancelled();
        debugPrint('the separator could not take this one apart, so the arithmetic: $e');
        if (trackId != null) _separatorFailed.add(trackId);
      } finally {
        if (_running == mine) _running = null;
      }
    }
    // The pair that was asked for, the old way. The voice on its own is not something
    // the old way can give.
    if (!serverParts.contains(name)) {
      throw StateError('only the separator can lift the voice out on its own');
    }
    if (trackId != null) partsJobs.stage(trackId, PartsStage.separating, trained: false);
    final dir = File(into.values.first).parent;
    final together = name == 'instrumental' ? ['instrumental'] : ['drums', 'music'];
    into = {
      for (final p in together)
        if (trackId != null)
          p: partFile(dir, trackId, p, version: _arithmeticVersion).path,
    };
    if (into.isEmpty) throw StateError('could not tell which record that was');
  }

  final decoded = await _unlessCancelled(Process.run(
    ffmpeg,
    ['-v', 'error', '-t', '$upToSeconds', '-i', audio,
      '-ac', '2', '-ar', '$rate', '-f', 'f32le', '-'],
    stdoutEncoding: null,
    stderrEncoding: null,
  ));
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
  final parts = await _unlessCancelled(_arithmetic(moved, name));

  for (final e in parts.sound.entries) {
    final file = into[e.key];
    if (file == null) continue;
    if (stopped()) throw const _Cancelled();
    await _encode(ffmpeg, e.value, parts.channels, File(file));
  }
}

/// The arithmetic in an isolate of its own. A function apart from _render because a
/// closure sends everything its scope has captured — and _render's scope holds the
/// separator's process, which cannot be sent anywhere.
Future<({int channels, Map<String, Float32List> sound})> _arithmetic(
        TransferableTypedData moved, String name) =>
    Isolate.run(() => separate(moved.materialize().asFloat32List(), name));

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
/// [progress] hears how much has come, of how much when the house says. Cancelling
/// [trackId] (cancelHere) stops it at the next chunk, and it throws.
Future<String?> borrowRecord(Uri from, Map<String, String> headers, int trackId,
    {void Function(int got, int? total)? progress}) async {
  if (!canSeparateHere) return null;
  final dir = await partsDir();
  final into = File('$dir${Platform.pathSeparator}borrowed-$trackId.audio');
  if (await into.exists()) return into.path;
  // Written beside itself and renamed when whole, so a record cut off halfway is
  // never mistaken for one that arrived. (The name still starts "borrowed-", so a
  // startup sweep clears it up if the app is closed mid-fetch.) This used to reuse
  // the parts' ".m4a → .tmp.m4a" line, which on a name ending ".audio" changed
  // nothing — the fetch went straight into the real name.
  final tmp = File('${into.path}.tmp');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(from);
    headers.forEach(request.headers.set);
    final response = await request.close();
    if (response.statusCode >= 400) {
      throw StateError('the record could not be fetched (${response.statusCode})');
    }
    final total = response.contentLength >= 0 ? response.contentLength : null;
    final sink = tmp.openWrite();
    var got = 0;
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 60))) {
        if (_cancelled.contains(trackId)) throw const _Cancelled();
        sink.add(chunk);
        got += chunk.length;
        progress?.call(got, total);
      }
    } finally {
      await sink.close();
    }
    await tmp.rename(into.path);
    return into.path;
  } catch (_) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    rethrow;
  } finally {
    client.close(force: true);
  }
}

/// Give back a record borrowed only to take apart. The parts themselves stay.
Future<void> giveBack(String path) async {
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
  } catch (_) {}
}

// ------------------------------------------------------------------ a loop's seam
/// Where to put a loop's two ends — moved together, so it stays as long — for the
/// sound where it jumps back to match the sound it jumps back to. Each on an exact
/// sample of the record; null where the record is not on this computer to be read.
///
/// A loop's seam is a splice: the engine plays to its end and carries on from its
/// start (measured: exact to the sample — it plays up to the one before the end, and
/// on from the start), and two unrelated points of a waveform spliced together are a
/// click, once a bar, for as long as the loop runs. DJ software crossfades a few
/// milliseconds there; this engine cannot. What it can do is splice where the two
/// sides already agree: within a millisecond and a half, where the two samples either
/// side of the loop's end match the two either side of its start. On three records'
/// one, two and four bar loops that took the jump from about twice an ordinary step of
/// the waveform to under half of one, and the worst from fifty times to six. (Matched
/// over a few milliseconds around the splice instead, the seams came out worse than
/// not moving them: the neighbourhood agreed while the one sample that mattered did
/// not.) Nobody hears a beat moved a millisecond and a half.
Future<(Duration, Duration)?> quietSeam(String file, Duration start, Duration end) async {
  if (!canSeparateHere || end <= start) return null;
  final ffmpeg = (await Tools.find(own: await _toolsDir())).ffmpeg;
  if (ffmpeg == null) return null;
  const reach = 66; // samples either way: 1.5 ms at 44.1 kHz
  const half = 1;
  const w = reach + half;
  try {
    // The record's own rate: the engine splices in the record's samples, not in
    // anything resampled.
    final probe = await Process.run(
      ffmpeg.replaceFirst(RegExp(r'ffmpeg(\.exe)?$'), Platform.isWindows ? 'ffprobe.exe' : 'ffprobe'),
      ['-v', 'error', '-select_streams', 'a:0', '-show_entries', 'stream=sample_rate',
        '-of', 'default=nw=1:nk=1', file],
    ).timeout(const Duration(seconds: 5));
    final rate = int.tryParse('${probe.stdout}'.trim());
    if (rate == null || rate <= 0) return null;
    final sa = (start.inMicroseconds * rate / 1e6).round();
    final sb = (end.inMicroseconds * rate / 1e6).round();
    if (sa - w < 0) return null;

    // The samples from [from] on, exactly: decoded from the start of the file and read
    // at that moment (-ss after -i), which lands on the sample. Jumped to (-ss before
    // -i) it came out up to 700 samples from where the record's timeline has it.
    Future<Float32List?> grab(int from) async {
      final at = (from - 0.5) / rate; // half a sample early: the first one at or after
      final r = await Process.run(
        ffmpeg,
        ['-v', 'error', '-i', file, '-ss', at.toStringAsFixed(9), '-t', '0.05',
          '-ac', '2', '-f', 'f32le', '-'],
        stdoutEncoding: null,
        stderrEncoding: null,
      ).timeout(const Duration(seconds: 8));
      if (r.exitCode != 0) return null;
      final raw = r.stdout as List<int>;
      if (raw.length < 2 * w * 8) return null;
      return Uint8List.fromList(raw.sublist(0, 2 * w * 8)).buffer.asFloat32List();
    }

    final both = await Future.wait([grab(sa - w), grab(sb - w)]);
    final a = both[0], b = both[1];
    if (a == null || b == null) return null;
    var best = 0, least = double.infinity;
    for (var d = -reach; d <= reach; d++) {
      var sum = 0.0;
      for (var k = -half; k < half; k++) {
        final i = (w + d + k) * 2;
        final l = a[i] - b[i], rr = a[i + 1] - b[i + 1];
        sum += l * l + rr * rr;
      }
      if (sum < least - 1e-12 || (sum <= least + 1e-12 && d.abs() < best.abs())) {
        least = sum;
        best = d;
      }
    }
    // Half a sample either side of the exact one, so the engine's own rounding lands
    // on it: it starts on the first sample at or after the start, and stops before
    // the first sample that would run past the end.
    Duration at(double samples) => Duration(microseconds: (samples / rate * 1e6).round());
    return (at(sa + best - 0.5), at(sb + best + 0.5));
  } catch (_) {
    return null;
  }
}
