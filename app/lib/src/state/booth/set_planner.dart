import 'dart:math' as math;

import '../../api/models.dart';
import 'booth.dart';

/// How a set should go, as a whole: where its energy is meant to head.
enum EnergyArc {
  /// Level: each record about as loud as the last.
  flat,

  /// Up all the way: the last record the loudest.
  build,

  /// Up to a peak three quarters of the way through, then easing off.
  peakLate,

  /// Down: an ending, a late hour.
  coolDown,
}

extension EnergyArcWords on EnergyArc {
  String get label => switch (this) {
        EnergyArc.flat => 'level',
        EnergyArc.build => 'build',
        EnergyArc.peakLate => 'peak late',
        EnergyArc.coolDown => 'cool down',
      };
}

/// How well one record follows another, and why, term by term — so the set view can
/// say it and a person can argue with it.
class Fit {
  const Fit(this.score, this.terms, this.why);

  /// 0 is nothing to go on; about 1.2 is as good as it gets.
  final double score;

  /// Each named part of the score.
  final Map<String, double> terms;

  /// In a few words: "2 % faster · a fifth apart (8A→9A) · a step up".
  final String why;

  static const nothing = Fit(0, {}, '');
}

/// Choosing which record follows which, and the order of a whole set.
///
/// Pairwise, a [fit]: the tempo (as far as the automix will pull, half time a
/// different feel), the key as DJs move round the wheel (the same, the relative, a
/// fifth; a tone or a semitone up as a boost; anything else a clash — weighed by how
/// sure the house is of either key), the step in loudness against where the set is
/// meant to head, how alike the two are made (their stems' shares), and never the
/// same artist twice running nor the same song in another edit.
///
/// For a set, an [order]: a beam search over the records still to play that adds up
/// the fits and follows an [EnergyArc], with records a hand has locked left where
/// they are. Greedy one-step choosing — the best next, then the best after that — is
/// what it replaces: it painted a set into corners.
class SetPlanner {
  /// Loudness on a scale of 0 to 1: -20 LUFS (soft) to -6 (a wall).
  static double? energyOf(Track? t, TrackTiming? timing) {
    final lufs = t?.loudnessLufs ?? timing?.structure?.lufs;
    if (lufs == null) return null;
    return ((lufs + 20) / 14).clamp(0.0, 1.0);
  }

  /// The tempo term, 0 to 0.6, and its words. [fromPitch] is the pitch the record on
  /// now will settle at.
  static (double, String?) tempo(TrackTiming a, TrackTiming b, {double fromPitch = 1}) {
    final fa = a.gridBpm, fb = b.gridBpm;
    if (fa == null || fb == null) return (0.25, null);
    final ratio = Booth.syncRatio(fb, fa * fromPitch, reach: Booth.bridgeReach);
    if (ratio == null) return (0, 'too far apart in tempo');
    var t = 0.5 * (1 - ((ratio - 1).abs() / Booth.bridgeReach)).clamp(0.0, 1.0) + 0.1;
    final raw = fb / (fa * fromPitch);
    final octave = raw > math.sqrt2 || raw < 1 / math.sqrt2;
    if (octave) t *= 0.5;
    final pct = ((1 / ratio - 1) * 100).abs();
    final how = octave
        ? (raw > 1 ? 'double time' : 'half time')
        : pct < 0.5
            ? 'the same tempo'
            : '${pct.toStringAsFixed(0)} % ${1 / ratio > 1 ? 'faster' : 'slower'}';
    return (t, how);
  }

  /// The key move from [a] to [b] as DJs read the wheel: how good it is (0 to 1),
  /// whether it is a boost (a tone or a semitone up — an energy move, wanted over a
  /// percussive stretch, not over two melodies), and its words. Weighed towards
  /// "nothing to say" (0.5) as the house is less sure of either key.
  static ({double score, bool boost, bool clash, String? why}) keyMove(TrackTiming a, TrackTiming b) {
    final ca = a.camelot, cb = b.camelot;
    if (ca == null || cb == null || ca.length < 2 || cb.length < 2) {
      return (score: 0.5, boost: false, clash: false, why: null);
    }
    final na = int.tryParse(ca.substring(0, ca.length - 1));
    final nb = int.tryParse(cb.substring(0, cb.length - 1));
    if (na == null || nb == null) return (score: 0.5, boost: false, clash: false, why: null);
    final same = ca[ca.length - 1] == cb[cb.length - 1];
    final d = ((nb - na) % 12 + 12) % 12;
    double score;
    var boost = false, clash = false;
    String words;
    if (d == 0 && same) {
      score = 1.0;
      words = 'the same key';
    } else if (d == 0) {
      score = 0.9;
      words = 'relative major and minor';
    } else if ((d == 1 || d == 11) && same) {
      score = 0.85;
      words = 'a fifth apart';
    } else if (d == 2 && same) {
      score = 0.6;
      boost = true;
      words = 'a tone up: a boost';
    } else if (d == 7 && same) {
      score = 0.55;
      boost = true;
      words = 'a semitone up: a boost';
    } else if (d == 10 && same) {
      score = 0.4;
      words = 'a tone down';
    } else if (d == 5 && same) {
      score = 0.35;
      words = 'a semitone down';
    } else {
      score = 0.15;
      clash = true;
      words = 'keys clash';
    }
    // How sure: the house's confidence is the margin the key won by, 0 to 1; under a
    // tenth it is a guess, and a guess says nothing about a clash.
    final conf = math.min(a.keyConfidence, b.keyConfidence);
    final w = ((conf - 0.1) / 0.4).clamp(0.0, 1.0);
    if (w == 0) return (score: 0.5, boost: false, clash: false, why: null);
    return (
      score: 0.5 + (score - 0.5) * w,
      boost: boost && w >= 0.5,
      clash: clash && w >= 0.5,
      why: '$words ($ca→$cb)',
    );
  }

  /// Whether the two keys are known well enough and far enough apart to clash.
  static bool keysClash(TrackTiming a, TrackTiming b) => keyMove(a, b).clash;

  /// How a record is made, from its stems: how much of it is drums, bass and the
  /// rest, voice — each as dB against the mix. Null without stems.
  static List<double>? timbre(TrackTiming? t) {
    final s = t?.structure;
    if (s == null || s.drumsDb == null || s.restDb == null || s.vocalsDb == null) return null;
    final n = s.mixDb.length;
    if (n == 0) return null;
    double mean(List<double> part) {
      var sum = 0.0;
      var k = 0;
      for (var i = 0; i < n && i < part.length; i++) {
        if (s.mixDb[i] <= -90) continue;
        sum += (part[i] - s.mixDb[i]).clamp(-40.0, 0.0);
        k++;
      }
      return k == 0 ? -40 : sum / k;
    }

    return [mean(s.drumsDb!), mean(s.restDb!), mean(s.vocalsDb!)];
  }

  /// How much of [t] is sung, 0 to 1, by its sections; null where not known.
  static double? sung(TrackTiming? t) {
    final sections = t?.structure?.sections;
    if (sections == null || sections.isEmpty) return null;
    var all = 0, voiced = 0;
    for (final s in sections) {
      all += s.bars;
      if (s.vocals) voiced += s.bars;
    }
    return all == 0 ? null : voiced / all;
  }

  static String _titleKey(String title) =>
      title.toLowerCase().replaceAll(RegExp(r'[\(\[].*?[\)\]]'), '').replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  /// How well [b] follows [a]. [before] are the records lately played before [a],
  /// for what is not to be repeated; [wantedStep] is the step in loudness the arc
  /// asks for here (0 to 1 scale; null for no wish).
  static Fit fit(
    TrackTiming? a,
    TrackTiming? b, {
    Track? ta,
    Track? tb,
    double fromPitch = 1,
    List<Track> before = const [],
    double? wantedStep,
  }) {
    if (a == null || b == null) return Fit.nothing;
    final terms = <String, double>{};
    final words = <String>[];

    final (t, tempoWords) = tempo(a, b, fromPitch: fromPitch);
    terms['tempo'] = t;
    if (tempoWords != null) words.add(tempoWords);

    final key = keyMove(a, b);
    terms['key'] = 0.3 * key.score;
    if (key.why != null) words.add(key.why!);

    final ea = energyOf(ta, a), eb = energyOf(tb, b);
    if (ea != null && eb != null) {
      final step = eb - ea;
      final wanted = wantedStep ?? 0;
      terms['energy'] = 0.2 * (1 - ((step - wanted).abs() / 0.3)).clamp(0.0, 1.0);
      final db = step * 14;
      words.add(db.abs() < 1.5
          ? 'as loud'
          : '${db.abs().toStringAsFixed(0)} dB ${db > 0 ? 'louder' : 'softer'}');
    }

    final ma = timbre(a), mb = timbre(b);
    if (ma != null && mb != null) {
      var d = 0.0;
      for (var i = 0; i < 3; i++) {
        d += (ma[i] - mb[i]).abs();
      }
      terms['timbre'] = 0.1 * (1 - d / 3 / 20).clamp(0.0, 1.0);
      if (d / 3 < 4) words.add('made alike');
    }

    final sa = sung(a), sb = sung(b);
    if (sa != null && sb != null && sa > 0.5 && sb > 0.5) {
      terms['vocals'] = -0.05;
      words.add('both sung throughout');
    }

    if (ta != null && tb != null) {
      final names = {for (final x in [ta, ...before]) ...x.artists.map((s) => s.toLowerCase())};
      if (tb.artists.any((s) => names.contains(s.toLowerCase()))) {
        terms['artist'] = -0.3;
        words.add('the same artist again');
      }
      if (_titleKey(ta.title) == _titleKey(tb.title) ||
          before.any((x) => _titleKey(x.title) == _titleKey(tb.title))) {
        terms['title'] = -0.5;
        words.add('the same song again');
      }
    }
    final score = terms.values.fold(0.0, (x, y) => x + y);
    return Fit(score, terms, words.join(' · '));
  }

  /// Where the arc wants the set's loudness at record [i] of [n], from [start] (0 to
  /// 1; null for nothing known).
  static double? target(EnergyArc arc, int i, int n, double? start) {
    if (start == null || n <= 1) return start;
    final k = i / (n - 1);
    return switch (arc) {
      EnergyArc.flat => start,
      EnergyArc.build => start + (0.95 - start) * k,
      EnergyArc.coolDown => start + (0.15 - start) * k,
      EnergyArc.peakLate => k < 0.75 ? start + (0.95 - start) * (k / 0.75) : 0.95 - 0.35 * ((k - 0.75) / 0.25),
    };
  }

  /// The order to play [rest] in after [from]: the sequence whose fits add up best
  /// and follows [arc] — with any record in [locked] kept exactly where it is in
  /// [rest]. [timingOf] is what is known of each; a record with nothing known keeps a
  /// neutral fit and its place is decided by the others.
  static List<Track> order(
    List<Track> rest, {
    required Track? from,
    required TrackTiming? Function(int trackId) timingOf,
    EnergyArc arc = EnergyArc.flat,
    Set<int> locked = const {},
    List<Track> before = const [],
    double fromPitch = 1,
    int width = 8,
  }) {
    if (rest.length <= 1) return rest;
    final n = rest.length;
    final startEnergy = from == null ? null : energyOf(from, timingOf(from.id));
    final cache = <(int, int), double>{};
    double fitOf(Track? a, Track b, List<Track> played, int at) {
      if (a == null) return 0.3;
      final ta = timingOf(a.id), tb = timingOf(b.id);
      if (ta == null || tb == null) return 0.3;
      // The pair's own fit, once — without the repetition, which depends on the path.
      final base = cache[(a.id, b.id)] ??=
          fit(ta, tb, ta: a, tb: b, fromPitch: at == 0 ? fromPitch : 1).score;
      // The arc: how far this record is from where the set should be by here.
      final eb = energyOf(b, tb);
      final t = target(arc, at + 1, n + 1, startEnergy);
      final arcTerm = eb != null && t != null ? -0.4 * (eb - t).abs() : 0.0;
      var again = 0.0;
      final names = {for (final x in [a, ...played]) ...x.artists.map((s) => s.toLowerCase())};
      if (b.artists.any((s) => names.contains(s.toLowerCase()))) again -= 0.3;
      if (played.any((x) => _titleKey(x.title) == _titleKey(b.title))) again -= 0.5;
      return base + arcTerm + again;
    }

    // Beam search: each path a partial order and its score.
    var beam = <(List<Track>, double)>[(const [], 0.0)];
    final lockedAt = {for (var i = 0; i < n; i++) if (locked.contains(rest[i].id)) i: rest[i]};
    for (var at = 0; at < n; at++) {
      final next = <(List<Track>, double)>[];
      for (final (path, score) in beam) {
        final used = {for (final t in path) t.id};
        final last = path.isEmpty ? from : path.last;
        final played = [...before, ...path];
        final candidates = lockedAt.containsKey(at)
            ? [lockedAt[at]!]
            : [for (final t in rest) if (!used.contains(t.id) && !locked.contains(t.id)) t];
        for (final c in candidates) {
          next.add(([...path, c], score + fitOf(last, c, played, at)));
        }
      }
      next.sort((x, y) => y.$2.compareTo(x.$2));
      beam = next.take(width).toList();
    }
    return beam.isEmpty ? rest : beam.first.$1;
  }
}
