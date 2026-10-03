// What goes over the wire between a desk's board and a screen showing it.
//
// Up, from the screen: presses, the bank, the level, stop — in the remote
// decoder's words (control/decoders.dart) — and the board's changes (a pad set or
// cleared, two swapped, a bank named, a row pinned, a pad or a sound listened to),
// which the desk makes on its board itself (link_server.dart). Down, from the desk:
// the board whenever it changes, what is sounding ten times a second while anything
// is, and the library for a screen that has no server to ask.
// Both ends are this program, so the shapes live in one place and are tested once.
import 'dart:convert';

import 'board_face.dart';
import 'pad_spec.dart';
import 'samples.dart';
import 'soundboard.dart';

abstract final class LinkWire {
  /// A whole board, as the desk has it: the document, the bank on show, the level,
  /// each used sample's shape, and the look.
  static Map<String, dynamic> boardMessage(Soundboard b, {required bool light}) => {
        // 't' first: a line is told apart by its first bytes before it is parsed.
        't': 'board',
        // This desk takes the board's changes over the wire: a screen may edit.
        'edits': 1,
        'doc': b.doc.toJson(),
        'bank': b.bank,
        'light': light,
        'peaks': {
          for (final p in b.doc.allPads)
            if (b.peaksOf(p.spec.sampleId) case final peaks?)
              '${p.spec.sampleId}': base64Encode([for (final v in peaks) (v * 255).round().clamp(0, 255)]),
        },
        'pads': playingMessage(b)['pads'],
      };

  /// What sounds and what waits, as how far each is along: a screen's clock
  /// carries it on from there.
  static Map<String, dynamic> playingMessage(BoardFace b) {
    final now = DateTime.now();
    final pads = <Map<String, dynamic>>[];
    for (var bank = 0; bank < b.doc.banks.length; bank++) {
      for (var pad = 0; pad < Bank.size; pad++) {
        final s = b.stateOf(bank, pad);
        if (!s.sounding && !s.waiting) continue;
        pads.add({
          'bank': bank,
          'pad': pad,
          if (s.sounding) 'elapsed_ms': now.difference(s.firedAt ?? now).inMilliseconds,
          if (s.sounding) 'len_ms': s.length?.inMilliseconds ?? 0,
          if (s.held) 'held': true,
          if (s.waitingUntil != null) 'wait_ms': s.waitingUntil!.difference(now).inMilliseconds,
        });
      }
    }
    return {'t': 'playing', 'pads': pads};
  }

  /// The house's shelf and the user's own sounds, for a screen with no server of its
  /// own to ask (the board's own window). The kit is built into every screen.
  static Map<String, dynamic> libraryMessage(SampleLibrary l) => {
        't': 'library',
        'own': [for (final s in l.known.values) _sample(s)],
        'house': [for (final s in l.house.values) _sample(s)],
      };

  static Map<String, dynamic> _sample(Sample s) => {
        'id': s.id,
        'name': s.name,
        'duration_ms': s.length.inMilliseconds,
        if (s.group != null) 'group': s.group,
        if (s.hint != null) 'pad': s.hint,
        if (s.words != null) 'words': s.words,
      };

  /// The lines that change the board rather than play it.
  static const edits = {'pad', 'swap', 'bankname', 'strip', 'listen', 'quiet', 'audition', 'library?'};

  static String encode(Map<String, dynamic> m) => jsonEncode(m);

  static Map<String, dynamic>? decode(String line) {
    try {
      final v = jsonDecode(line);
      return v is Map ? v.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }
}
