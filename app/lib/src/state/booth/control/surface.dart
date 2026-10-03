/// What a DJ controller is made of, named: the vocabulary every layout maps its
/// hardware onto, so that one binding (BoothBinding) serves every controller.
///
/// An id is a dotted path. Deck controls are `deck.a.play`, `deck.b.eq.low`, and so
/// on; the mixer's are `mixer.crossfader`; the browse buttons are `browse.up`. A
/// layout that has a control this vocabulary lacks may still name it — it is logged
/// and ignored — but the binding only acts on the names below.
library;

/// Which deck a control belongs to.
enum Side {
  a,
  b;

  Side get other => this == a ? b : a;
}

/// What sort of thing a control is, which decides how its bytes become a value:
/// a button is pressed or not, a pot and a fader have a position, an encoder and a
/// jog wheel turn by some amount.
enum ControlKind {
  button,
  pot,
  fader,
  encoder,
  jog;

  static ControlKind parse(String s) =>
      values.firstWhere((k) => k.name == s, orElse: () => throw FormatException('unknown control kind "$s"'));

  /// Whether the value is a position (0..1) that a knob or fader can be left at,
  /// which is what soft take-over is for.
  bool get positional => this == pot || this == fader;

  /// Whether the value is a movement rather than a position.
  bool get relative => this == encoder || this == jog;
}

/// The names. Deck ones take a [Side] through [Controls.deck].
abstract final class Controls {
  // ----------------------------------------------------------------- per deck
  static const play = 'play';
  static const cue = 'cue';
  /// STOP doubles as the shift key on most Hercules consoles.
  static const stop = 'stop';
  static const sync = 'sync';
  static const keylock = 'keylock';
  static const pitchReset = 'pitchReset';
  static const pitch = 'pitch';
  static const jog = 'jog';
  static const load = 'load';
  static const prev = 'prev';
  static const next = 'next';
  static const pfl = 'pfl';
  static const source = 'source';
  static const fx = 'fx';
  static const gain = 'gain';
  static const volume = 'volume';
  static const eqLow = 'eq.low';
  static const eqMid = 'eq.mid';
  static const eqHigh = 'eq.high';
  static const killLow = 'kill.low';
  static const killMid = 'kill.mid';
  static const killHigh = 'kill.high';
  static String pad(int n) => 'pad.$n';

  // ----------------------------------------------------------------- the rest
  static const crossfader = 'mixer.crossfader';
  static const master = 'mixer.master';
  static const balance = 'mixer.balance';
  static const headMix = 'mixer.headMix';
  static const scratch = 'mixer.scratch';
  static const browseUp = 'browse.up';
  static const browseDown = 'browse.down';
  static const browseLeft = 'browse.left';
  static const browseRight = 'browse.right';
  static const mic = 'mic';

  // ----------------------------------------------------------------- the board
  /// `board.pad.N`, N = 1..16 of the bank on show.
  static String boardPad(int n) => 'board.pad.$n';

  /// `board.bank.N`, N = 1..4; and the one before, the one after.
  static String boardBank(int n) => 'board.bank.$n';
  static const boardBankPrev = 'board.bank.prev';
  static const boardBankNext = 'board.bank.next';
  static const boardStop = 'board.stop';
  static const boardLevel = 'board.level';

  static int? boardPadOf(String id) =>
      id.startsWith('board.pad.') ? int.tryParse(id.substring(10)) : null;
  static int? boardBankOf(String id) =>
      id.startsWith('board.bank.') ? int.tryParse(id.substring(11)) : null;

  static String deck(Side side, String name) => 'deck.${side.name}.$name';

  /// Split a deck id: `deck.a.eq.low` → (a, `eq.low`). Null for anything else.
  static (Side, String)? deckOf(String id) {
    if (!id.startsWith('deck.')) return null;
    final rest = id.substring(5);
    final dot = rest.indexOf('.');
    if (dot != 1) return null;
    final side = switch (rest[0]) { 'a' => Side.a, 'b' => Side.b, _ => null };
    if (side == null) return null;
    return (side, rest.substring(2));
  }

  /// Which pad, for a `pad.N` name. Null for anything else.
  static int? padOf(String name) {
    if (!name.startsWith('pad.')) return null;
    return int.tryParse(name.substring(4));
  }
}

/// One thing the hardware said, decoded.
///
/// [value] is 1/0 for a button, 0..1 for a pot or fader (0.5 at a centre detent,
/// where the layout says there is one), and a signed number of ticks for an encoder
/// or a jog wheel. [raw] is what came off the wire, for the monitor.
class SurfaceEvent {
  const SurfaceEvent(this.id, this.kind, this.value, {this.raw = 0, this.at});
  final String id;
  final ControlKind kind;
  final double value;
  final int raw;
  final DateTime? at;

  bool get pressed => kind == ControlKind.button && value > 0.5;
  bool get released => kind == ControlKind.button && value <= 0.5;

  @override
  String toString() => switch (kind) {
        ControlKind.button => '$id ${pressed ? 'down' : 'up'}',
        ControlKind.encoder || ControlKind.jog => '$id ${value >= 0 ? '+' : ''}${value.toStringAsFixed(0)}',
        _ => '$id ${value.toStringAsFixed(3)}',
      };
}

/// A light on the controller, as the binding wants it.
class LedState {
  const LedState(this.id, this.on);
  final String id;
  final bool on;
}
