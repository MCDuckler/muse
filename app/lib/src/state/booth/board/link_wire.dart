// What goes over the wire between a desk's board and a screen showing it.
//
// Up, from the screen: presses, the bank, the level, stop — in the remote
// decoder's words (control/decoders.dart). Down, from the desk: the board itself
// whenever it changes, and what is sounding ten times a second while anything is.
// Both ends are this program, so the shapes live in one place and are tested once.
import 'dart:convert';

import 'board_face.dart';
import 'pad_spec.dart';
import 'soundboard.dart';

abstract final class LinkWire {
  /// A whole board, as the desk has it: the document, the bank on show, the level,
  /// each used sample's shape, and the look.
  static Map<String, dynamic> boardMessage(Soundboard b, {required bool light}) => {
        // 't' first: a line is told apart by its first bytes before it is parsed.
        't': 'board',
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
