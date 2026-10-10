// The moments in the show: a beat, a bar, a phrase, a section turning, a drop, a mix
// starting — the edges between one frame's state and the next, as typed events, so
// a scene can cut on a downbeat and a light can strobe on a drop without each of
// them reading the state for the edge themselves.
import 'show_state.dart';

enum ShowEventKind {
  /// Every beat; [ShowEvent.data] `one` is true on the first of the bar.
  beat,
  bar,

  /// The first bar of a four-bar phrase.
  phrase,

  /// The section changed; `label`, `from`.
  section,
  drop,

  /// A breakdown began.
  breakdown,

  /// A record was put on a deck, or taken off; `trackId`.
  loaded,
  play,
  pause,
  mixArmed,
  mixStart,
  mixEnd,

  /// A mix's step was applied; `at` is its place 0..1.
  step,

  /// A sound of the booth's fired; `sound`.
  fx,

  /// The performer hit the show.
  hit,
}

class ShowEvent {
  const ShowEvent(this.kind, this.at, {this.deck, this.data = const {}});

  final ShowEventKind kind;
  final DateTime at;

  /// The deck it happened on, A or B, where it is a deck's.
  final String? deck;
  final Map<String, Object?> data;

  bool get onMaster => data['master'] == true;

  @override
  String toString() => 'ShowEvent(${kind.name}${deck == null ? '' : ' $deck'}'
      '${data.isEmpty ? '' : ' $data'})';

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'at': at.millisecondsSinceEpoch,
        'deck': deck,
        'data': data,
      };

  factory ShowEvent.fromJson(Map<String, dynamic> j) => ShowEvent(
        ShowEventKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => ShowEventKind.hit),
        DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0),
        deck: j['deck'] as String?,
        data: (j['data'] as Map?)?.cast<String, Object?>() ?? const {},
      );
}

/// The events between [prev] and [next]: what the differ sees in the state alone.
/// Steps and sounds are told by the booth, not read here.
List<ShowEvent> eventsBetween(ShowState? prev, ShowState next) {
  final out = <ShowEvent>[];
  final at = next.now;
  for (final deck in [next.a, next.b]) {
    final was = prev?.deck(deck.name);
    final master = next.masterName == deck.name;
    final d = {'master': master};
    if (was?.trackId != deck.trackId) {
      out.add(ShowEvent(ShowEventKind.loaded, at, deck: deck.name, data: {...d, 'trackId': deck.trackId}));
    }
    if (was != null && was.playing != deck.playing) {
      out.add(ShowEvent(deck.playing ? ShowEventKind.play : ShowEventKind.pause, at, deck: deck.name, data: d));
    }
    if (!deck.playing || deck.beatIndex == null) continue;
    final sameRecord = was != null && was.trackId == deck.trackId && was.playing;
    // A beat passed: the index moved on (by one, or a few if a frame was skipped — one
    // beat is said, not each). A seek back is a new place, not a beat.
    if (sameRecord && was.beatIndex != null && deck.beatIndex! > was.beatIndex! && deck.beatIndex! - was.beatIndex! < 8) {
      final one = deck.beatInBar == 0;
      out.add(ShowEvent(ShowEventKind.beat, at, deck: deck.name, data: {...d, 'one': one, 'inBar': deck.beatInBar}));
      if (one) {
        out.add(ShowEvent(ShowEventKind.bar, at, deck: deck.name, data: {...d, 'bar': deck.barIndex}));
        if (deck.phraseBar == 0) {
          out.add(ShowEvent(ShowEventKind.phrase, at, deck: deck.name, data: d));
        }
      }
    }
    if (sameRecord && was.section != deck.section && deck.section != null) {
      out.add(ShowEvent(ShowEventKind.section, at, deck: deck.name, data: {...d, 'label': deck.section, 'from': was.section}));
      if (deck.breakdown && !was.breakdown) {
        out.add(ShowEvent(ShowEventKind.breakdown, at, deck: deck.name, data: d));
      }
    }
    // The drop: the beats away crossed nought going down.
    final a = was?.dropBeatsAway, b = deck.dropBeatsAway;
    if (sameRecord && a != null && b != null && a > 0 && b <= 0 && a - b < 8) {
      out.add(ShowEvent(ShowEventKind.drop, at, deck: deck.name, data: d));
    }
  }
  final wasMix = prev?.mix ?? ShowMix.none, mix = next.mix;
  if (!wasMix.armed && mix.armed) {
    out.add(ShowEvent(ShowEventKind.mixArmed, at, data: {'kind': mix.kind, 'from': mix.from, 'to': mix.to}));
  }
  if (!wasMix.on && mix.on) {
    out.add(ShowEvent(ShowEventKind.mixStart, at, data: {'kind': mix.kind, 'from': mix.from, 'to': mix.to, 'bars': mix.bars}));
  }
  if (wasMix.on && !mix.on) {
    out.add(ShowEvent(ShowEventKind.mixEnd, at, data: {'kind': wasMix.kind, 'from': wasMix.from, 'to': wasMix.to}));
  }
  return out;
}
