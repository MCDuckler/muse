// The booth as it was left, so a restart of the app comes back to it.
//
// Written every few seconds while the booth is live — which records are on which
// deck and where each has got to, the fader, and the automix's queue, place and
// dials — and read once at the next start: a session under eight hours old that was
// live is put back and set going from where it was. A booth that was stopped writes
// that it was, so nothing comes back that was meant to end.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../api/models.dart';
import 'booth.dart';
import 'set_planner.dart' show EnergyArc;
import 'automix.dart' show MixStyle;

class BoothSession {
  const BoothSession._();

  static const fresh = Duration(hours: 8);
  static const every = Duration(seconds: 5);

  static Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}booth-session.json');

  /// The booth now, as JSON.
  static Map<String, dynamic> snapshot(Booth b) => {
        'at': DateTime.now().toIso8601String(),
        'live': b.live,
        'master': b.master.name,
        'crossfader': b.crossfader,
        'decks': [
          for (final d in b.decks)
            if (d.track != null)
              {
                'name': d.name,
                'track_id': d.track!.id,
                'position_ms': d.position.inMilliseconds,
                'pitch': d.pitch,
                'part': d.part,
                'playing': d.playing,
              },
        ],
        'auto': {
          'running': b.auto.running,
          'at': b.auto.at,
          'tracks': [for (final t in b.auto.tracks) t.id],
          'pick_best': b.auto.pickBest,
          'arc': b.auto.arc.name,
          'style': b.auto.style.name,
          'fill': b.auto.fill,
        },
      };

  static Future<void> save(Booth b) async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(snapshot(b)), flush: true);
    } catch (e) {
      debugPrint('booth: could not keep the session ($e)');
    }
  }

  /// What was kept, if it was live and is fresh; null otherwise.
  static Future<Map<String, dynamic>?> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      if (j['live'] != true) return null;
      final at = DateTime.tryParse(j['at'] as String? ?? '');
      if (at == null || DateTime.now().difference(at) > fresh) return null;
      return j;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.writeAsString(jsonEncode({'live': false, 'at': DateTime.now().toIso8601String()}));
    } catch (_) {}
  }

  /// Every record the session names, by id, fetched from the house — the automix's
  /// queue in its order, and whatever was on a deck outside it.
  static List<int> trackIds(Map<String, dynamic> snap) {
    final ids = <int>[];
    for (final id in ((snap['auto'] as Map?)?['tracks'] ?? const []) as List) {
      ids.add((id as num).toInt());
    }
    for (final d in (snap['decks'] ?? const []) as List) {
      final id = ((d as Map)['track_id'] as num).toInt();
      if (!ids.contains(id)) ids.add(id);
    }
    return ids;
  }

  /// The booth put back as [snap] had it, with [tracks] fetched by [trackIds]. The
  /// automix, where it was running, starts again at the same record and place with
  /// its dials as they were; otherwise each deck gets its record back, parked or
  /// playing as it was. Says whether anything came back.
  static Future<bool> resume(Booth b, Map<String, dynamic> snap, Map<int, Track> tracks) async {
    await b.init();
    final auto = (snap['auto'] as Map?)?.cast<String, dynamic>() ?? const {};
    final decks = [for (final d in (snap['decks'] ?? const []) as List) (d as Map).cast<String, dynamic>()];
    final masterName = snap['master'] as String? ?? 'A';
    b.master = masterName == 'B' ? b.b : b.a;
    final a = b.auto;
    a.pickBest = auto['pick_best'] == true;
    a.fill = auto['fill'] == true;
    a.arc = EnergyArc.values.asNameMap()[auto['arc']] ?? a.arc;
    a.style = MixStyle.values.asNameMap()[auto['style']] ?? a.style;
    if (auto['running'] == true) {
      final order = [for (final id in (auto['tracks'] ?? const []) as List) tracks[(id as num).toInt()]].whereType<Track>().toList();
      if (order.isEmpty) return false;
      final at = ((auto['at'] as num?)?.toInt() ?? 0).clamp(0, order.length - 1);
      final onDeck = decks.where((d) => d['name'] == masterName && d['track_id'] == order[at].id).firstOrNull;
      final from = onDeck == null ? null : Duration(milliseconds: (onDeck['position_ms'] as num).toInt());
      await a.start(order, at: at, from: from);
      return true;
    }
    var any = false;
    for (final d in decks) {
      final deck = d['name'] == 'B' ? b.b : b.a;
      final t = tracks[(d['track_id'] as num).toInt()];
      if (t == null) continue;
      await b.load(deck, t, at: Duration(milliseconds: (d['position_ms'] as num).toInt()), byHand: false);
      final pitch = (d['pitch'] as num?)?.toDouble();
      if (pitch != null && (pitch - 1).abs() > 1e-4) await deck.setTempo(pitch);
      if (d['playing'] == true) await deck.play();
      any = true;
    }
    await b.setCrossfader((snap['crossfader'] as num?)?.toDouble() ?? (masterName == 'B' ? 1 : 0));
    return any;
  }
}
