import 'dart:math' as math;

import 'booth.dart';

/// What this person has thought of the booth's mixes, boiled down to leanings the
/// planner can add to its scores: which moves they thumb up and down, which pairs of
/// records they liked together, which moves they steer the booth away from.
///
/// Fitted from the house's mix_feedback (the thumbs, the hands on the plan): a thumb
/// is worth the most, a steer away from a move a little, and every leaning is capped
/// so that taste tilts the planner's own judgement rather than replacing it — and
/// says nothing until there is enough of it to say anything.
class Taste {
  const Taste._(this._kinds, this._pairs, this.count);

  static const none = Taste._({}, {}, 0);

  /// How a move is liked, by its name: -1 to 1, most under a tenth in size.
  final Map<String, double> _kinds;

  /// How a pair of records was liked together, by (from, to): the thumbs added up.
  final Map<(int, int), double> _pairs;

  /// How many words this person has said, in all.
  final int count;

  bool get isEmpty => count == 0;

  /// From the house's feedback rows, newest first, as GET /booth/feedback gives them.
  factory Taste.fromFeedback(List<Map<String, dynamic>> rows) {
    final kindSum = <String, double>{}, kindN = <String, int>{};
    final pairs = <(int, int), double>{};
    var count = 0;
    void kind(String? k, double v) {
      if (k == null || k.isEmpty) return;
      kindSum[k] = (kindSum[k] ?? 0) + v;
      kindN[k] = (kindN[k] ?? 0) + 1;
    }

    for (final r in rows) {
      final event = r['event'] as String?;
      final from = r['from_track'] as int?, to = r['to_track'] as int?;
      final rating = (r['rating'] as num?)?.toDouble();
      final k = r['kind'] as String?;
      final detail = r['detail'] is Map ? (r['detail'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
      switch (event) {
        case 'rating':
          if (rating == null || rating == 0) continue;
          count++;
          kind(k, rating);
          if (from != null && to != null) pairs[(from, to)] = (pairs[(from, to)] ?? 0) + rating;
        case 'steer':
          // Steered away from one move to another: a little against the one left,
          // a little for the one chosen — unless it was only lengthened or nudged.
          final was = detail['was'] as String?;
          if (was == null || was == k) continue;
          count++;
          kind(was, -0.4);
          kind(k, 0.4);
        case 'replay':
          // Heard again: interest, not a verdict.
          continue;
        default:
          continue;
      }
    }
    final kinds = <String, double>{};
    for (final e in kindSum.entries) {
      final n = kindN[e.key]!;
      // The mean, shrunk towards nothing while there are few words: three thumbs
      // one way are a leaning, one is a day.
      kinds[e.key] = (e.value / n) * (n / (n + 2));
    }
    return Taste._(kinds, pairs, count);
  }

  /// What to add to a move's score for its kind: up to ±0.12.
  double ofKind(Transition kind) => 0.12 * (_kinds[kind.name] ?? 0).clamp(-1.0, 1.0);

  /// What to add to a pair's fit for having been heard and judged together: each
  /// thumb 0.15, up to ±0.3.
  double ofPair(int from, int to) {
    final v = _pairs[(from, to)];
    if (v == null) return 0;
    return (0.15 * v).clamp(-0.3, 0.3);
  }

  /// The move this person likes best of all, where any is liked: for the log.
  String? get favourite {
    String? best;
    var top = 0.0;
    for (final e in _kinds.entries) {
      if (e.value > math.max(top, 0.2)) {
        top = e.value;
        best = e.key;
      }
    }
    return best;
  }
}
