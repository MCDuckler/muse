import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../worker/parts_jobs.dart';
import '../../worker/render_parts.dart';

/// Where the parts of a record come from.
///
/// Two machines can take a record apart. The server does it for everybody and is the
/// only answer a phone or a browser has. A desk does it for itself, and should: the
/// arithmetic is quicker there than on a small shared box — measured, about five
/// seconds against twelve for a four minute record, before a real desk's cores are
/// counted — and it never has to queue behind whatever else the house is asking for.
///
/// So this asks the nearer of the two and falls back to the other. What the booth
/// sees is one question with three answers: it is here, it is coming, or it is not
/// something this record gets.
class PartsStore {
  PartsStore(this.api, {this.offlinePath}) {
    // The trained separator's files come from the same house as the music.
    separationHouse = () => api.baseUrl;
    // What the buttons on the list of jobs do.
    partsJobs
      ..onCancel = cancelHere
      ..onPromote = promoteHere
      ..onRetry = _retry;
  }

  final ApiClient api;

  /// The record itself, where this device is keeping one — much the best thing to
  /// separate, since it is already on the disk.
  final String? Function(int trackId)? offlinePath;

  /// Parts this computer has made, by track and name.
  final _here = <String, String>{};

  /// Records this computer has already fetched in order to take apart, so a second
  /// part does not fetch the same record again.
  final _borrowed = <int, String>{};

  /// Fetches in flight, so two parts asked for at once share one.
  final _borrowing = <int, Future<String?>>{};

  /// Whether the work happens on this machine at all. False in a browser and on a
  /// phone, where the server is the only answer.
  bool get separatesHere => canSeparateHere;

  /// A part of [trackId] as a file on this computer, or null. What the deck plays
  /// when there is one: no network, no waiting.
  String? pathFor(int trackId, String name) => _here['$trackId-$name'];

  /// Ask for a part, making it if it is not made.
  ///
  /// Answers [Stem.ready] when it can be played now — [pathFor] says whether that is
  /// from this disk or the server — [Stem.beingMade] while somebody is working on
  /// it, and [Stem.never] for a record that does not get taken apart.
  ///
  /// [byHand] is somebody pressing a pad for it, which counts for more than the
  /// automix asking ahead: it puts a waiting record first, and tries again one that
  /// failed or was cancelled.
  Future<Stem> want(Track t, String name, {bool byHand = false}) async {
    if (_here.containsKey('${t.id}-$name')) return Stem.ready;
    if ((t.durationMs ?? 0) > upToSeconds * 1000) return Stem.never;

    if (canSeparateHere) {
      final job = partsJobs.of(t.id);
      if (byHand &&
          job != null &&
          (job.stage == PartsStage.failed || job.stage == PartsStage.cancelled)) {
        forgiveHere(t.id);
      }
      // Taken off the list by somebody: the automix does not put it back.
      if (cancelledHere(t.id)) return Stem.never;
      final made = await _makeHere(t, name);
      if (made != null) {
        if (made == Stem.beingMade && byHand) promoteHere(t.id);
        return made;
      }
      if (cancelledHere(t.id)) return Stem.never;
      // Falling through: this computer could not, so ask the house.
    }
    // The house makes three parts, and the voice on its own is not one of them.
    if (!serverParts.contains(name)) return Stem.never;
    try {
      return await api.stemState(t, name);
    } catch (_) {
      return Stem.beingMade;
    }
  }

  /// Try a failed or cancelled job again, as the list's Retry button does.
  void _retry(int trackId) {
    final job = partsJobs.of(trackId);
    final t = job?.track;
    if (job == null || t == null) return;
    forgiveHere(trackId);
    unawaited(want(t, job.parts.isEmpty ? 'drums' : job.parts.first, byHand: true));
  }

  /// Null when this computer cannot do it after all and the server should be asked.
  Future<Stem?> _makeHere(Track t, String name) async {
    try {
      // Made already — this session or an earlier one — needs no record at all.
      final ready = await partReady(t.id, name);
      if (ready != null) {
        _here['${t.id}-$name'] = ready;
        return Stem.ready;
      }
      if (makingHere(t.id, name)) return Stem.beingMade;
      // Nothing is fetched for a part this computer could never make.
      if (!await canMakeHere(t.id, name)) return null;
      final audio = await _recordFor(t);
      if (audio == null) return null;
      final (state, made) = await partHere(audio, t.id, name,
          durationMs: t.durationMs, track: t);
      switch (state) {
        case Here.ready:
          _here['${t.id}-$name'] = made!;
          return Stem.ready;
        case Here.making:
          return Stem.beingMade;
        case Here.cannot:
          return null;
      }
    } catch (e) {
      debugPrint('could not take ${t.id} apart here: $e');
      return null;
    }
  }

  /// The record as a file this computer can read: the kept copy where there is one,
  /// otherwise fetched once and borrowed.
  ///
  /// Fetching a whole record to take it apart is eight megabytes to save a shared box
  /// a minute of its afternoon, which on a desk's connection is a trade worth making
  /// — but only once per record, however many of its parts are wanted.
  Future<String?> _recordFor(Track t) async {
    final kept = offlinePath?.call(t.id);
    if (kept != null) return kept;

    final already = _borrowed[t.id];
    if (already != null) return already;
    if (t.streamPath == null) return null;

    return _borrowing[t.id] ??= () async {
      // On the list from here: eight megabytes is something to watch arrive.
      partsJobs.add(t.id, track: t, stage: PartsStage.fetching);
      try {
        await api.ensureStreamKey();
        final got = await borrowRecord(
          Uri.parse(api.streamUrl(t)),
          api.streamHeaders,
          t.id,
          progress: (got, total) => partsJobs.progress(
              t.id, total == null ? null : got / total,
              bytes: got, total: total),
        );
        if (got == null) {
          partsJobs.drop(t.id);
        } else {
          _borrowed[t.id] = got;
        }
        return got;
      } catch (e) {
        if (!cancelledHere(t.id)) {
          partsJobs.stage(t.id, PartsStage.failed, error: 'could not fetch the record');
        }
        rethrow;
      } finally {
        unawaited(_borrowing.remove(t.id));
      }
    }();
  }

  /// Clear up after a run that did not finish. At startup only — see sweepHere.
  Future<void> tidyAtStart() => sweepHere();

  /// Give back the records borrowed only to take apart. The parts themselves stay.
  Future<void> tidy() async {
    for (final path in _borrowed.values) {
      await giveBack(path);
    }
    _borrowed.clear();
  }
}
