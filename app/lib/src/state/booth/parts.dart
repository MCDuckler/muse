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
  ///
  /// Where from, in order: this computer's disk; the house, which keeps every record
  /// any computer in the pool has taken apart; this computer, when it is the best one
  /// about to do it (it has a graphics card) or the pool has had long enough without
  /// anybody taking it; and otherwise the pool — the record is queued there by asking,
  /// and the parts come from the house when a computer has made them.
  ///
  /// [soon] is the automix looking down its queue: the record is not going on a deck
  /// yet, so it is left to the pool — asked for at less than "now" — rather than put
  /// in this computer's own line ahead of the one it is about to play.
  Future<Stem> want(Track t, String name, {bool byHand = false, bool soon = false}) async {
    if (byHand) _byHand.add(t.id);
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
      final ready = await partReady(t.id, name);
      if (ready != null) {
        _here['${t.id}-$name'] = ready;
        return Stem.ready;
      }
      if (makingHere(t.id, name)) {
        if (byHand) promoteHere(t.id);
        return Stem.beingMade;
      }
    }
    // The house: kept there already, or — asking is also queueing — not yet.
    Stem house;
    try {
      house = await api.stemState(t, name, soon: soon && !byHand);
    } catch (_) {
      house = Stem.beingMade;
    }
    if (house == Stem.ready) {
      _arrived(t.id);
      return Stem.ready;
    }
    if (house == Stem.never || !canSeparateHere) return house;
    if (await _takeItHere(t, name, soon: soon && !byHand)) {
      final made = await _makeHere(t, name);
      if (made != null) {
        if (made == Stem.beingMade && byHand) promoteHere(t.id);
        _pooled.remove(t.id);
        return made;
      }
    }
    _toThePool(t);
    return Stem.beingMade;
  }

  /// Whether this computer should take [t] apart itself: it can at all, and either it
  /// is the best computer about — it has a graphics card — or the record has waited in
  /// the pool long enough that nobody better is coming.
  Future<bool> _takeItHere(Track t, String name, {bool soon = false}) async {
    if (!await canMakeHere(t.id, name)) return false;
    if (!soon && (bestHere?.call() ?? false)) return true;
    final since = _pooled[t.id];
    if (since == null || DateTime.now().difference(since) < _poolPatience) return false;
    try {
      final job = (await api.poolSplitState(t.id))['job'] as Map?;
      return job == null || job['state'] != 'leased';
    } catch (_) {
      return false;
    }
  }

  /// How long a record waits in the pool for a better computer before this one takes
  /// it on. A little longer than the house makes a computer without a card wait
  /// (jobs.SPLIT_FOR_THE_CARD_SECONDS), so any other computer's chance comes first.
  static const _poolPatience = Duration(seconds: 75);

  /// Whether this computer is the one to take records apart: it has a graphics card.
  /// Set by the app, which knows (PoolHere).
  static bool Function()? bestHere;

  /// Records somebody asked for by hand: never handed back to the pool unasked.
  final _byHand = <int>{};

  /// [t] is no longer about to be played here — its deck has taken another record —
  /// so if it is only waiting in this computer's line it goes back to the pool,
  /// rather than holding up the record that replaced it.
  void backToPool(Track t) {
    if (_byHand.contains(t.id)) return;
    if (unqueueHere(t.id)) _toThePool(t);
  }

  /// This computer's own line in the order these are needed: the first first.
  void inOrder(List<int> ids) {
    for (final id in ids.reversed) {
      promoteHere(id);
    }
  }

  /// Records asked of the pool, and since when.
  final _pooled = <int, DateTime>{};
  final _pooledTracks = <int, Track>{};
  Timer? _watching;

  /// Told when a record's parts are ready, here or at the house: the automix plans
  /// around records that are in parts.
  final arrivals = StreamController<int>.broadcast();

  void _toThePool(Track t) {
    _pooled.putIfAbsent(t.id, DateTime.now);
    _pooledTracks[t.id] = t;
    final j = partsJobs.of(t.id);
    if (j == null || j.done || j.stage != PartsStage.pooled) {
      partsJobs.add(t.id, track: t, parts: trainedParts, stage: PartsStage.pooled);
    }
    _watching ??= Timer.periodic(const Duration(seconds: 10), (_) => _lookAtThePool());
  }

  /// Every little while: which pooled records are done, which a computer has taken,
  /// and which have waited so long this computer should do them.
  Future<void> _lookAtThePool() async {
    if (_pooled.isEmpty) {
      _watching?.cancel();
      _watching = null;
      return;
    }
    for (final id in _pooled.keys.toList()) {
      try {
        final st = await api.poolSplitState(id);
        final parts = [for (final p in (st['parts'] as List? ?? const [])) '$p'];
        if (trainedParts.every(parts.contains)) {
          _arrived(id);
          continue;
        }
        final job = st['job'] as Map?;
        final j = partsJobs.of(id);
        if (j != null && j.stage == PartsStage.pooled) {
          j.device = job?['state'] == 'leased' ? '${job?['device'] ?? 'another computer'}' : null;
          partsJobs.progress(id, ((job?['progress'] as Map?)?['percent'] as num?)?.toDouble());
        }
        final t = _pooledTracks[id];
        if (t != null && await _takeItHere(t, 'drums')) {
          _pooled.remove(id);
          unawaited(want(t, 'drums'));
        }
      } catch (_) {}
    }
  }

  /// A record's parts are at the house: said by the event stream, or found by asking.
  void partsArrived(int trackId) {
    if (_pooled.containsKey(trackId) || partsJobs.of(trackId)?.stage == PartsStage.pooled) {
      _arrived(trackId);
    }
  }

  /// How far a computer in the pool has got with one of ours.
  void poolProgress(int trackId, double? percent) {
    final j = partsJobs.of(trackId);
    if (j != null && j.stage == PartsStage.pooled) partsJobs.progress(trackId, percent);
  }

  void _arrived(int trackId) {
    final was = _pooled.remove(trackId) != null;
    _pooledTracks.remove(trackId);
    final j = partsJobs.of(trackId);
    if (j != null && j.stage == PartsStage.pooled) {
      j.device = null;
      partsJobs.stage(trackId, PartsStage.ready);
    }
    if (was || j != null) arrivals.add(trackId);
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
