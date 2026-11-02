// The WetOwl Desk's booth, read off the wire: what its two decks play, where, how
// loud, through what EQ and filter, and what its engine hears. A stage window fed by
// the Desk (`wetowl --stage ws://…`, the Desk's /stage) runs the show's director
// itself over these facts (ShowEngine.fed) — the Desk has no director of its own.
// The records' own facts (their beats, sections, voices, pulse) come from the house
// the Desk is signed into, with its sign-in (the hello's `house`), else from the one
// this stage is signed into. MilkDrop listens to the Desk's master, sent beside each
// frame; from a Desk that sends none, to the records' streams off the house.
//
// The Desk's lines (desk/crates/wo-wire):
//   {"t":"hello","v":1,"from":"desk","house":{"server","token"}}   (house: signed in;
//      said again when the Desk signs in or out)
//   {"t":"desk","d":{"a":DECK,"b":DECK,"heard":{"master":AUDIO,"spectrum":[32]},"mix":MIX}}
//      DECK  {"trackId","title","artist","playing","positionMs" (the ear's),"rate",
//             "level","eq":{"low","mid","high"} (dB),"filter" (-1..1),"looping",
//             "heard":AUDIO}
//      AUDIO ShowAudio's JSON, the engine's measure (no stems)
//      MIX   ShowMix's JSON
//   {"t":"hands","do":"hit"|"next"|"previous"|"mosh"|"hold"|"blackout"|"strobe"|"freeze","on":bool}
//   binary "PCM1", rate (u32 LE), mono 16-bit samples (LE): the master since the last frame
// and back, a few times a second, with the picture: {"t":"shown","scene" (its name),"held"}.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../api/pulse.dart';
import '../booth/mixer.dart' show EqSet;
import '../timing.dart';
import 'milk_feed.dart';
import 'show_deck.dart';
import 'show_engine.dart';
import 'show_heard.dart';
import 'show_source.dart';
import 'show_state.dart';

class DeskShowSource extends ShowSource {
  DeskShowSource(this.api)
      : timing = TimingStore(api),
        vocals = VocalStore(api) {
    // MilkDrop's sound: the Desk's master as it sends it; from a Desk that sends
    // none, the record's stream off the house.
    MilkFeed.shared.pcm.source = (id) {
      final t = _tracks[id];
      return t == null ? null : (url: api.streamUrl(t), headers: api.streamHeaders);
    };
    MilkFeed.shared.pcm.heard = _heardPcm;
  }

  /// The Desk's sound, waiting for the next tick.
  final _pcm = <Int16List>[];
  int _pcmQueued = 0;
  DateTime? _pcmAt;

  /// A binary message off the wire: the Desk's master since its last frame. False for
  /// anything else.
  bool pcmArrived(List<int> data) {
    final b = data is Uint8List ? data : Uint8List.fromList(data);
    if (b.length < 8 || b[0] != 0x50 || b[1] != 0x43 || b[2] != 0x4d || b[3] != 0x31) return false; // PCM1
    final n = (b.length - 8) ~/ 2;
    final out = Int16List(n);
    final bd = ByteData.sublistView(b, 8);
    for (var i = 0; i < n; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little);
    }
    _pcm.add(out);
    _pcmQueued += n;
    // A stage that stopped reading (hidden, slow) keeps the newest half second.
    while (_pcmQueued > 24000 && _pcm.length > 1) {
      _pcmQueued -= _pcm.removeAt(0).length;
    }
    _pcmAt = DateTime.now();
    return true;
  }

  /// What came since the last tick; empty between two of the Desk's frames; null from
  /// a Desk that sends no sound (then the records are read off the house).
  Int16List? _heardPcm() {
    final at = _pcmAt;
    if (at == null || DateTime.now().difference(at) > const Duration(seconds: 2)) return null;
    if (_pcm.length == 1) {
      _pcmQueued = 0;
      return _pcm.removeLast();
    }
    final out = Int16List(_pcmQueued);
    var o = 0;
    for (final p in _pcm) {
      out.setAll(o, p);
      o += p.length;
    }
    _pcm.clear();
    _pcmQueued = 0;
    return out;
  }

  /// The Desk's house, from its hello: this stage reads the records' facts with the
  /// Desk's sign-in from then on (the ones it could not read are asked again).
  void useHouse(String server, String token) {
    if (api.baseUrl == server && api.token == token) return;
    api.baseUrl = server;
    api.token = token;
    _asked.removeWhere((id) => !_tracks.containsKey(id));
  }

  @override
  final ApiClient api;
  final TimingStore timing;
  final VocalStore vocals;

  final _tracks = <int, Track>{};
  final _pulse = <int, Pulse>{};
  final _asked = <int>{};

  Map<String, dynamic>? _frame;
  DateTime _heardAt = DateTime.now();
  bool _read = true;

  /// Whether a frame has come.
  bool get heard => _frame != null;

  /// A `desk` line's frame.
  void arrived(Map<String, dynamic> d) {
    final was = _frame;
    // Two frames between two of ours: the hits of the one not read kept, as the
    // engine keeps a hit between two reads (the most of each over the span).
    if (was != null && !_read) {
      _keepHits(_at(was, ['heard', 'master']), _at(d, ['heard', 'master']));
      _keepHits(_at(was, ['a', 'heard']), _at(d, ['a', 'heard']));
      _keepHits(_at(was, ['b', 'heard']), _at(d, ['b', 'heard']));
    }
    _frame = d;
    _read = false;
    _heardAt = DateTime.now();
  }

  static Object? _at(Map<String, dynamic> m, List<String> path) {
    Object? v = m;
    for (final k in path) {
      v = v is Map ? v[k] : null;
    }
    return v;
  }

  static void _keepHits(Object? was, Object? now) {
    if (was is! Map || now is! Map) return;
    for (final k in const ['kick', 'snare', 'hat', 'onset']) {
      final x = was[k], y = now[k];
      if (x is num && (y is! num || x > y)) now[k] = x;
    }
  }

  @override
  ShowFacts facts(DateTime now, int offsetMs) {
    final f = _frame;
    if (f == null) {
      return (a: const ShowDeck(name: 'A'), b: const ShowDeck(name: 'B'), audio: ShowAudio.silence, live: const <String, double>{}, mix: ShowMix.none);
    }
    _read = true;
    // Carried forward a quarter second at most (as RemoteShowFeed): past that the
    // Desk is gone and the picture holds rather than runs on.
    final dt = (now.difference(_heardAt).inMicroseconds / 1e6).clamp(0.0, 0.25);
    final a = _deck('A', f['a'], dt, offsetMs), b = _deck('B', f['b'], dt, offsetMs);
    var audio = a.audio + b.audio;
    final live = <String, double>{};
    final heard = f['heard'];
    if (heard is Map) {
      final m = heard['master'];
      if (m is Map) {
        audio = ShowHeard.over(ShowAudio.fromJson(m.cast()), audio);
        live['live.on'] = 1;
      }
      final spec = heard['spectrum'];
      if (spec is List) {
        for (var i = 0; i < spec.length; i++) {
          final v = spec[i];
          if (v is num) live['spec.$i'] = v.toDouble();
        }
      }
    }
    final mix = f['mix'] is Map ? ShowMix.fromJson((f['mix'] as Map).cast()) : ShowMix.none;
    return (a: a, b: b, audio: audio, live: live, mix: mix);
  }

  ShowDeck _deck(String name, Object? j, double dt, int offsetMs) {
    if (j is! Map) return ShowDeck(name: name);
    final id = (j['trackId'] as num?)?.toInt();
    final playing = j['playing'] == true;
    final rate = (j['rate'] as num?)?.toDouble() ?? 1;
    final ms = ((j['positionMs'] as num?)?.toDouble() ?? 0) + (playing ? dt * 1000 * rate : 0) + offsetMs;
    final track = id == null ? null : _tracks[id];
    if (id != null && id > 0) _ask(id, track);
    double num_(Object? v, double or) => v is num ? v.toDouble() : or;
    final eq = j['eq'];
    final deck = deriveDeck(
      name: name,
      track: track,
      coverUrl: track == null ? null : api.coverUrl(track),
      streamUrl: track == null ? null : api.streamUrl(track),
      playing: playing,
      position: Duration(microseconds: (ms < 0 ? 0 : ms * 1000).round()),
      timing: id == null ? null : timing.peek(id),
      vocals: id == null ? null : vocals.peek(id),
      pulse: id == null ? null : _pulse[id],
      channel: ChannelSettings(
        level: num_(j['level'], 1).clamp(0.0, 1.0),
        eq: eq is Map ? EqSet(low: num_(eq['low'], 0), mid: num_(eq['mid'], 0), high: num_(eq['high'], 0)) : EqSet.flat,
        filter: num_(j['filter'], 0).clamp(-1.0, 1.0),
        looping: j['looping'] == true,
      ),
    );
    final h = j['heard'];
    return h is Map ? deck.withAudio(ShowHeard.over(ShowAudio.fromJson(h.cast()), deck.audio)) : deck;
  }

  /// The record off the house once, then its beats, voice and pulse.
  void _ask(int id, Track? track) {
    if (track == null) {
      if (!_asked.add(id)) return;
      unawaited(api.track(id).then((t) {
        _tracks[id] = t;
        unawaited(timing.of(t));
        unawaited(vocals.of(t));
        unawaited(api.pulse(id).then((p) {
          if (p != null) _pulse[id] = p;
        }).catchError((Object _) {}));
      }).catchError((Object _) {
        // Not one of the house's (a record of the Desk's own): beats unknown; the
        // engine's measure still drives the show.
      }));
    }
  }
}

/// A Desk's line for this stage: a frame into [source], the hands onto [show] (once it
/// is going). False for any other line.
bool deskSaid(String line, DeskShowSource source, ShowEngine? show) {
  if (line.startsWith('{"t":"hello","v":1,"from":"desk"')) {
    final house = deskHouse(line);
    if (house != null) source.useHouse(house.server, house.token);
    return true;
  }
  if (!line.startsWith('{"t":"desk"') && !line.startsWith('{"t":"hands"')) return false;
  final Object? j;
  try {
    j = jsonDecode(line);
  } catch (_) {
    return true;
  }
  if (j is! Map<String, dynamic>) return true;
  switch (j['t']) {
    case 'desk':
      final d = j['d'];
      if (d is Map) source.arrived(d.cast());
    case 'hands':
      if (show == null) return true;
      final on = j['on'] != false;
      switch (j['do']) {
        case 'hit':
          show.hit();
        case 'next':
          show.nextScene();
        case 'previous':
          show.previousScene();
        case 'mosh':
          show.moshNext();
        case 'hold':
          show.holdScene(on);
        case 'blackout':
          show.setMacros(show.macros.copyWith(blackout: on));
        case 'strobe':
          show.setMacros(show.macros.copyWith(strobe: on ? 1 : 0));
        case 'freeze':
          show.setMacros(show.macros.copyWith(freeze: on));
      }
  }
  return true;
}

/// The house in a Desk's hello, or null (a Desk not signed in, or not a hello).
({String server, String token})? deskHouse(String hello) {
  try {
    final j = jsonDecode(hello);
    final h = j is Map ? j['house'] : null;
    if (h is Map && h['server'] is String && h['token'] is String) {
      return (server: (h['server'] as String).replaceAll(RegExp(r'/+$'), ''), token: h['token'] as String);
    }
  } catch (_) {}
  return null;
}

/// What the stage shows, for the Desk's panel: the scene on, by name.
String deskShownJson(ShowEngine show) {
  final id = show.state.scene;
  return jsonEncode({'t': 'shown', 'scene': id == null ? null : show.looks[id]?.name ?? id, 'held': show.sceneHeld});
}
