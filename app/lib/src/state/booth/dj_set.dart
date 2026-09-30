import 'dart:math' as math;

import '../../api/client.dart';
import '../../api/models.dart';
import 'set_planner.dart';

/// A set as the booth plans and plays it: where its records come from (a pool), how
/// it should go (a shape), and the records themselves, slot by slot — built by the
/// house over the whole pool (setbuild.py), judged again here, and re-routed while it
/// plays whenever something changes.

/// Where a set's records come from: the whole library, a few playlists, the queue —
/// any of them together.
class SetSource {
  const SetSource({this.library = false, this.queueId, this.playlists = const []});

  final bool library;

  /// The queue, where it is one of the sources.
  final int? queueId;
  final List<({int id, String name})> playlists;

  static const wholeLibrary = SetSource(library: true);

  bool get isEmpty => !library && queueId == null && playlists.isEmpty;

  /// What the house is sent.
  Map<String, dynamic> toJson() => {
        if (library) 'library': true,
        if (queueId != null) 'queue': queueId,
        if (playlists.isNotEmpty) 'playlists': [for (final p in playlists) p.id],
      };

  /// What is kept between sessions: the same, with the playlists' names.
  Map<String, dynamic> toKeep() => {
        'library': library,
        if (queueId != null) 'queue': queueId,
        'playlists': [for (final p in playlists) {'id': p.id, 'name': p.name}],
      };

  factory SetSource.fromKeep(Map<String, dynamic>? m) {
    if (m == null) return wholeLibrary;
    return SetSource(
      library: m['library'] == true,
      queueId: (m['queue'] as num?)?.toInt(),
      playlists: [
        for (final p in (m['playlists'] ?? const []) as List)
          if (p is Map && p['id'] is num) (id: (p['id'] as num).toInt(), name: '${p['name'] ?? ''}'),
      ],
    );
  }

  SetSource copyWith({bool? library, int? queueId, bool noQueue = false, List<({int id, String name})>? playlists}) =>
      SetSource(
        library: library ?? this.library,
        queueId: noQueue ? null : queueId ?? this.queueId,
        playlists: playlists ?? this.playlists,
      );

  /// In a few capital words, for a chip: THE LIBRARY, TECHNO · ACID 303, 3 PLAYLISTS.
  String get label {
    final parts = <String>[
      if (library) 'THE LIBRARY',
      if (playlists.length == 1) playlists.first.name.toUpperCase(),
      if (playlists.length > 1) '${playlists.length} PLAYLISTS',
      if (queueId != null) 'THE QUEUE',
    ];
    return parts.isEmpty ? 'NOTHING' : parts.join(' + ');
  }

  @override
  bool operator ==(Object other) =>
      other is SetSource &&
      other.library == library &&
      other.queueId == queueId &&
      other.playlists.length == playlists.length &&
      [for (var i = 0; i < playlists.length; i++) other.playlists[i].id == playlists[i].id].every((x) => x);

  @override
  int get hashCode => Object.hash(library, queueId, Object.hashAll([for (final p in playlists) p.id]));
}

/// The ways a set's energy can go, as curves over its time — each point (k, e): k from
/// 0 (the start) to 1 (the end), e from 0 (the softest records in the pool) to 1 (the
/// loudest). Read against the pool's own spread, so a warm-up in a crate of techno is
/// its softer records, not silence.
enum EnergyPreset { warmUp, build, peakLate, plateau, twoWaves, coolDown, custom }

extension EnergyPresetWords on EnergyPreset {
  String get label => switch (this) {
        EnergyPreset.warmUp => 'warm-up',
        EnergyPreset.build => 'build',
        EnergyPreset.peakLate => 'peak late',
        EnergyPreset.plateau => 'plateau',
        EnergyPreset.twoWaves => 'two waves',
        EnergyPreset.coolDown => 'cool down',
        EnergyPreset.custom => 'drawn',
      };

  List<(double, double)> get points => switch (this) {
        EnergyPreset.warmUp => const [(0, 0.1), (0.7, 0.45), (1, 0.6)],
        EnergyPreset.build => const [(0, 0.2), (1, 0.95)],
        EnergyPreset.peakLate => const [(0, 0.3), (0.75, 0.95), (1, 0.6)],
        EnergyPreset.plateau => const [(0, 0.55), (0.15, 0.8), (1, 0.8)],
        EnergyPreset.twoWaves => const [(0, 0.3), (0.3, 0.85), (0.5, 0.45), (0.8, 0.95), (1, 0.6)],
        EnergyPreset.coolDown => const [(0, 0.85), (1, 0.15)],
        EnergyPreset.custom => const [(0, 0.5), (0.25, 0.5), (0.5, 0.5), (0.75, 0.5), (1, 0.5)],
      };

  /// The nearest of the automix's own arcs, for ordering a queue by (SetPlanner.order).
  EnergyArc get arc => switch (this) {
        EnergyPreset.warmUp || EnergyPreset.build => EnergyArc.build,
        EnergyPreset.peakLate || EnergyPreset.twoWaves || EnergyPreset.custom => EnergyArc.peakLate,
        EnergyPreset.plateau => EnergyArc.flat,
        EnergyPreset.coolDown => EnergyArc.coolDown,
      };
}

/// How a set should go.
class SetShape {
  const SetShape({
    this.tracks = 12,
    this.minutes,
    this.preset = EnergyPreset.peakLate,
    this.drawn,
    this.tempo,
    this.key = 'loose',
    this.gap = 3,
    this.smooth = 0.5,
    this.fresh = 0.5,
    this.stems = false,
    this.offset = 0,
    this.anchor,
  });

  /// Its length: [minutes] where set, else [tracks] records.
  final int tracks;
  final double? minutes;

  /// Its energy over time: a preset, or points drawn by hand ([drawn], preset custom).
  final EnergyPreset preset;
  final List<(double, double)>? drawn;

  /// Where its tempo starts and ends, or null for no wish.
  final (double, double)? tempo;

  /// strict (no clash at all), loose (a clash costs), any.
  final String key;

  /// No artist again within this many records.
  final int gap;

  /// 0 each record unlike the last, 0.5 as the planner judges, 1 each like the last.
  final double smooth;

  /// 0 the records played most, 1 the ones hardly played.
  final double fresh;

  /// Records already in parts first.
  final bool stems;

  /// Where the room has asked for more (or less) energy than the curve: added to it.
  final double offset;

  /// "More like this": the record the next ones lean towards.
  final int? anchor;

  List<(double, double)> get points => drawn ?? preset.points;

  /// Where the curve wants the set [k] of the way in, 0 to 1 of the pool's loudness.
  double energyAt(double k) {
    final pts = points;
    final x = k.clamp(0.0, 1.0);
    var e = pts.last.$2;
    for (var i = 0; i + 1 < pts.length; i++) {
      final (k0, e0) = pts[i];
      final (k1, e1) = pts[i + 1];
      if (x >= k0 && x <= k1) {
        e = k1 == k0 ? e1 : e0 + (e1 - e0) * (x - k0) / (k1 - k0);
        break;
      }
    }
    if (x < pts.first.$1) e = pts.first.$2;
    return (e + offset).clamp(0.0, 1.0);
  }

  /// The tempo the path wants [k] of the way in, or null.
  double? tempoAt(double k) {
    final t = tempo;
    if (t == null) return null;
    return t.$1 * math.pow(t.$2 / t.$1, k.clamp(0.0, 1.0));
  }

  /// The rest of this shape from [k] on, as a shape of its own (its curve and tempo
  /// path cropped at k and stretched over 0..1) — what a set re-routed part-way
  /// through is built to, so it carries on where it was rather than starting again.
  SetShape from(double k) {
    final x = k.clamp(0.0, 0.95);
    if (x <= 0) return this;
    final pts = <(double, double)>[(0, energyAt(x) - offset)];
    for (final (pk, pe) in points) {
      if (pk > x) pts.add(((pk - x) / (1 - x), pe));
    }
    if (pts.length == 1) pts.add((1, pts.first.$2));
    final t = tempo;
    return copyWith(
      preset: EnergyPreset.custom,
      drawn: pts,
      tempo: t == null ? null : (tempoAt(x)!, t.$2),
      noTempo: t == null,
      minutes: minutes == null ? null : minutes! * (1 - x),
    );
  }

  SetShape copyWith({
    int? tracks,
    double? minutes,
    bool byTracks = false,
    EnergyPreset? preset,
    List<(double, double)>? drawn,
    (double, double)? tempo,
    bool noTempo = false,
    String? key,
    int? gap,
    double? smooth,
    double? fresh,
    bool? stems,
    double? offset,
    int? anchor,
    bool noAnchor = false,
  }) {
    final p = preset ?? this.preset;
    return SetShape(
      tracks: tracks ?? this.tracks,
      minutes: byTracks ? null : minutes ?? this.minutes,
      preset: p,
      drawn: p == EnergyPreset.custom ? drawn ?? this.drawn ?? p.points : null,
      tempo: noTempo ? null : tempo ?? this.tempo,
      key: key ?? this.key,
      gap: gap ?? this.gap,
      smooth: smooth ?? this.smooth,
      fresh: fresh ?? this.fresh,
      stems: stems ?? this.stems,
      offset: offset ?? this.offset,
      anchor: noAnchor ? null : anchor ?? this.anchor,
    );
  }

  /// What the house is sent (setbuild.Shape.of).
  Map<String, dynamic> toJson() => {
        'energy': [for (final (k, e) in points) [k, e]],
        if (tempo != null) 'tempo': {'from': tempo!.$1, 'to': tempo!.$2},
        'key': key,
        'variety': {'gap': gap, 'smooth': smooth, 'fresh': fresh},
        'stems': stems,
        'offset': offset,
        if (anchor != null) 'anchor': anchor,
      };

  Map<String, dynamic> get length => minutes != null ? {'minutes': minutes} : {'tracks': tracks};

  /// What is kept between sessions.
  Map<String, dynamic> toKeep() => {
        'tracks': tracks,
        if (minutes != null) 'minutes': minutes,
        'preset': preset.name,
        if (drawn != null) 'drawn': [for (final (k, e) in drawn!) [k, e]],
        if (tempo != null) 'tempo': [tempo!.$1, tempo!.$2],
        'key': key,
        'gap': gap,
        'smooth': smooth,
        'fresh': fresh,
        'stems': stems,
      };

  factory SetShape.fromKeep(Map<String, dynamic>? m) {
    if (m == null) return const SetShape();
    double? d(Object? v) => v is num ? v.toDouble() : null;
    final t = m['tempo'];
    final drawn = m['drawn'];
    return SetShape(
      tracks: (m['tracks'] as num?)?.toInt() ?? 12,
      minutes: d(m['minutes']),
      preset: EnergyPreset.values.asNameMap()[m['preset']] ?? EnergyPreset.peakLate,
      drawn: drawn is List
          ? [for (final p in drawn) if (p is List && p.length == 2) (d(p[0]) ?? 0, d(p[1]) ?? 0.5)]
          : null,
      tempo: t is List && t.length == 2 && t[0] is num && t[1] is num ? (d(t[0])!, d(t[1])!) : null,
      key: const ['strict', 'loose', 'any'].contains(m['key']) ? m['key'] as String : 'loose',
      gap: (m['gap'] as num?)?.toInt() ?? 3,
      smooth: d(m['smooth']) ?? 0.5,
      fresh: d(m['fresh']) ?? 0.5,
      stems: m['stems'] == true,
    );
  }
}

/// One record of a set, and what was thought of it.
class SetSlot {
  const SetSlot({
    required this.track,
    this.fit,
    this.why = '',
    this.energy,
    this.target,
    this.tempoTarget,
    this.bpm,
    this.camelot,
    this.parts = false,
    this.pinned = false,
    this.at = Duration.zero,
  });

  final Track track;

  /// How well it follows the record before it — the house's number, then this
  /// app's own once judged finely; null for the first of a set nothing precedes.
  final double? fit;
  final String why;

  /// Its loudness, and where the curve wanted the set to be here (0 to 1, -20..-6
  /// LUFS).
  final double? energy, target;
  final double? tempoTarget, bpm;
  final String? camelot;
  final bool parts;
  final bool pinned;

  /// Where in the set it starts, about.
  final Duration at;

  factory SetSlot.fromJson(Map<String, dynamic> m) {
    double? d(Object? v) => v is num ? v.toDouble() : null;
    return SetSlot(
      track: Track.fromJson((m['track'] as Map).cast<String, dynamic>()),
      fit: d(m['fit']),
      why: (m['why'] ?? '') as String,
      energy: d(m['energy']),
      target: d(m['target']),
      tempoTarget: d(m['tempo_target']),
      bpm: d(m['bpm']),
      camelot: m['camelot'] as String?,
      parts: m['parts'] == true,
      pinned: m['pinned'] == true,
      at: Duration(milliseconds: (m['at_ms'] as num?)?.toInt() ?? 0),
    );
  }

  SetSlot copyWith({Track? track, double? fit, String? why, bool? pinned, Duration? at}) => SetSlot(
        track: track ?? this.track,
        fit: fit ?? this.fit,
        why: why ?? this.why,
        energy: energy,
        target: target,
        tempoTarget: tempoTarget,
        bpm: bpm,
        camelot: camelot,
        parts: parts,
        pinned: pinned ?? this.pinned,
        at: at ?? this.at,
      );

  /// A record put in by hand, with what is known of it here.
  factory SetSlot.of(Track t, {bool pinned = true, TrackTiming? timing}) => SetSlot(
        track: t,
        energy: SetPlanner.energyOf(t, timing),
        bpm: timing?.gridBpm ?? t.bpm,
        camelot: timing?.camelot,
        pinned: pinned,
      );
}

/// Another record for one slot, and how it would sit between its neighbours.
class SlotChoice {
  const SlotChoice({required this.track, this.fitIn, this.fitOut, this.why = '', this.energy, this.bpm, this.camelot, this.parts = false});
  final Track track;
  final double? fitIn, fitOut;
  final String why;
  final double? energy, bpm;
  final String? camelot;
  final bool parts;

  double get fit => (fitIn ?? 0.6) + (fitOut ?? 0.6);

  factory SlotChoice.fromJson(Map<String, dynamic> m) {
    double? d(Object? v) => v is num ? v.toDouble() : null;
    return SlotChoice(
      track: Track.fromJson((m['track'] as Map).cast<String, dynamic>()),
      fitIn: d(m['fit_in']),
      fitOut: d(m['fit_out']),
      why: (m['why'] ?? '') as String,
      energy: d(m['energy']),
      bpm: d(m['bpm']),
      camelot: m['camelot'] as String?,
      parts: m['parts'] == true,
    );
  }

  SetSlot get asSlot => SetSlot(track: track, fit: fitIn, why: why, energy: energy, bpm: bpm, camelot: camelot, parts: parts);
}

/// What a pool holds: records named, ready, measured, never fetched — and how its
/// tempos and loudnesses spread, for the sliders to be drawn over.
class PoolStats {
  const PoolStats({
    this.named = 0,
    this.ready = 0,
    this.measured = 0,
    this.songs = 0,
    this.unmeasured = 0,
    this.unfetched = 0,
    this.inParts = 0,
    this.bpmFrom = 60,
    this.bpmStep = 2,
    this.bpmCounts = const [],
    this.energyCounts = const [],
    this.unfetchedIds = const [],
  });
  final int named, ready, measured, songs, unmeasured, unfetched, inParts;
  final double bpmFrom, bpmStep;
  final List<int> bpmCounts, energyCounts;
  final List<int> unfetchedIds;

  factory PoolStats.fromJson(Map<String, dynamic> m) {
    int i(Object? v) => v is num ? v.toInt() : 0;
    final bpm = (m['bpm'] as Map?)?.cast<String, dynamic>() ?? const {};
    return PoolStats(
      named: i(m['named']),
      ready: i(m['ready']),
      measured: i(m['measured']),
      songs: i(m['songs']),
      unmeasured: i(m['unmeasured']),
      unfetched: i(m['unfetched']),
      inParts: i(m['in_parts']),
      bpmFrom: ((bpm['from'] as num?) ?? 60).toDouble(),
      bpmStep: ((bpm['step'] as num?) ?? 2).toDouble(),
      bpmCounts: [for (final c in (bpm['counts'] ?? const []) as List) i(c)],
      energyCounts: [for (final c in ((m['energy'] as Map?)?['counts'] ?? const []) as List) i(c)],
      unfetchedIds: [for (final c in (m['unfetched_ids'] ?? const []) as List) i(c)],
    );
  }

  /// The tempo range the pool really spans, from the 2nd to the 98th percentile.
  (double, double)? get tempoSpan {
    final total = bpmCounts.fold(0, (a, b) => a + b);
    if (total == 0) return null;
    double at(double q) {
      var run = 0;
      for (var k = 0; k < bpmCounts.length; k++) {
        run += bpmCounts[k];
        if (run >= q * total) return bpmFrom + bpmStep * k;
      }
      return bpmFrom + bpmStep * bpmCounts.length;
    }

    return (at(0.02), at(0.98) + bpmStep);
  }
}

/// A set: its pool, its shape, its records.
class DjSet {
  DjSet({required this.source, required this.shape, required this.slots, this.curve = const [], this.stats, DateTime? builtAt})
      : builtAt = builtAt ?? DateTime.now();

  final SetSource source;
  final SetShape shape;
  final List<SetSlot> slots;

  /// The shape's target energy over the whole set (21 points), as the house read it
  /// against the pool.
  final List<double> curve;
  final PoolStats? stats;
  final DateTime builtAt;

  List<Track> get tracks => [for (final s in slots) s.track];

  /// About how long it plays.
  Duration get length {
    if (slots.isEmpty) return Duration.zero;
    final last = slots.last;
    final d = last.track.duration ?? const Duration(minutes: 4);
    return last.at + (d > const Duration(seconds: 90) ? d - const Duration(seconds: 30) : d);
  }

  /// The mean of the fits between its records, where there are any.
  double? get meanFit {
    final f = [for (final s in slots) if (s.fit != null) s.fit!];
    return f.isEmpty ? null : f.reduce((a, b) => a + b) / f.length;
  }

  DjSet copyWith({SetSource? source, SetShape? shape, List<SetSlot>? slots, List<double>? curve, PoolStats? stats}) =>
      DjSet(
        source: source ?? this.source,
        shape: shape ?? this.shape,
        slots: slots ?? this.slots,
        curve: curve ?? this.curve,
        stats: stats ?? this.stats,
        builtAt: builtAt,
      );

  /// The slots' places in the set worked out again from their records' lengths —
  /// after a slot was moved, swapped or taken out by hand.
  DjSet retimed() {
    var at = Duration.zero;
    final out = <SetSlot>[];
    for (final s in slots) {
      out.add(s.copyWith(at: at));
      final d = s.track.duration ?? const Duration(minutes: 4);
      at += d > const Duration(seconds: 90) ? d - const Duration(seconds: 30) : d;
    }
    return copyWith(slots: out);
  }

  /// What is kept between sessions: where from, how, and which records, pinned or not.
  Map<String, dynamic> toKeep() => {
        'source': source.toKeep(),
        'shape': shape.toKeep(),
        'slots': [for (final s in slots) {'id': s.track.id, if (s.pinned) 'pinned': true}],
      };

  /// Back from [toKeep], given the records by id.
  static DjSet? fromKeep(Map<String, dynamic>? m, Map<int, Track> tracks) {
    if (m == null) return null;
    final slots = <SetSlot>[];
    for (final s in (m['slots'] ?? const []) as List) {
      if (s is! Map) continue;
      final t = tracks[(s['id'] as num?)?.toInt()];
      if (t != null) slots.add(SetSlot(track: t, pinned: s['pinned'] == true));
    }
    return DjSet(
      source: SetSource.fromKeep((m['source'] as Map?)?.cast<String, dynamic>()),
      shape: SetShape.fromKeep((m['shape'] as Map?)?.cast<String, dynamic>()),
      slots: slots,
    ).retimed();
  }
}

/// Asking the house about sets.
class SetHouse {
  SetHouse(this.api);
  final ApiClient api;

  /// A set from [source] to [shape], following [start] (the record on now) where
  /// there is one, never one of [before] or [exclude]; [pins] fixes records to slots,
  /// [must] are in it somewhere.
  Future<DjSet> build({
    required SetSource source,
    required SetShape shape,
    Track? start,
    List<Track> before = const [],
    List<({int id, int slot})> pins = const [],
    List<int> must = const [],
    Iterable<int> exclude = const [],
    double pitch = 1,
    int? tracks,
  }) async {
    final d = await api.boothSet({
      'source': source.toJson(),
      'shape': shape.toJson(),
      'length': tracks != null ? {'tracks': tracks} : shape.length,
      if (start != null) 'start': {'track_id': start.id, 'before': [for (final t in before) t.id], 'pitch': pitch},
      if (pins.isNotEmpty) 'pins': [for (final p in pins) {'id': p.id, 'slot': p.slot}],
      if (must.isNotEmpty) 'must': must,
      if (exclude.isNotEmpty) 'exclude': exclude.toList(),
    });
    return DjSet(
      source: source,
      shape: shape,
      slots: [for (final s in (d['slots'] ?? const []) as List) SetSlot.fromJson((s as Map).cast<String, dynamic>())],
      curve: [for (final v in (d['curve'] ?? const []) as List) (v as num).toDouble()],
      stats: d['stats'] is Map ? PoolStats.fromJson((d['stats'] as Map).cast<String, dynamic>()) : null,
    );
  }

  /// Other records for a slot: after [prev], before [next], [k] of the way in.
  Future<List<SlotChoice>> choices({
    required SetSource source,
    required SetShape shape,
    Track? prev,
    Track? next,
    double k = 0.5,
    Iterable<int> exclude = const [],
    int limit = 6,
  }) async {
    final d = await api.boothSlot({
      'source': source.toJson(),
      'shape': shape.toJson(),
      if (prev != null) 'prev': prev.id,
      if (next != null) 'next': next.id,
      'k': k,
      'exclude': exclude.toList(),
      'limit': limit,
    });
    return [for (final c in (d['choices'] ?? const []) as List) SlotChoice.fromJson((c as Map).cast<String, dynamic>())];
  }

  Future<PoolStats> pool(SetSource source) async => PoolStats.fromJson(await api.boothPool(source.toJson()));
}
