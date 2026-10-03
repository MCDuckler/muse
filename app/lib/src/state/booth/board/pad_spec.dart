// The board, written down: banks of pads, each pad a sound and how it is played.
//
// Nothing here makes a sound. This is the document — what is saved, sent to a phone
// that shows the board, and read by the sampler when a pad is pressed.

/// How a pad plays its sound when pressed.
enum PadMode {
  /// Pressed, it plays from its start to its end; pressed again, it starts over.
  oneShot,

  /// Plays while held, stops when let go.
  hold,

  /// Pressed, it plays; pressed again, it stops.
  toggle,

  /// A toggle that goes round: back to its start when it reaches its end.
  loop;

  static PadMode parse(String? s) => values.firstWhere((m) => m.name == s, orElse: () => oneShot);

  String get label => switch (this) {
        oneShot => 'once',
        hold => 'hold',
        toggle => 'toggle',
        loop => 'loop',
      };
}

/// When a pressed pad actually starts: now, or on the master's next beat or bar.
enum Quantise {
  off,
  beat,
  bar;

  static Quantise parse(String? s) => values.firstWhere((q) => q.name == s, orElse: () => off);

  /// Which beats count: every one, or the bar's first.
  int get every => this == bar ? 4 : 1;
}

/// The eight colours a pad can be. Named for what they are on the console, not for
/// their hue: `a` and `b` are the decks' own colours, whatever the look makes them.
enum PadColour {
  a,
  b,
  accent,
  teal,
  violet,
  orange,
  white,
  grey;

  static PadColour parse(String? s) => values.firstWhere((c) => c.name == s, orElse: () => white);
}

/// One pad: which sound, and how it is played.
class PadSpec {
  const PadSpec({
    required this.sampleId,
    required this.name,
    this.colour = PadColour.white,
    this.mode = PadMode.oneShot,
    this.gain = 1.0,
    this.choke = 0,
    this.quantise = Quantise.off,
    this.duck = 0.0,
    this.trimIn = Duration.zero,
    this.trimOut,
    this.key,
  });

  /// The sample: a kit sound (negative), or one of the user's (the server's id).
  final int sampleId;

  /// What the pad says. Short; the sample's own name is the long form.
  final String name;
  final PadColour colour;
  final PadMode mode;

  /// The pad's own gain, 0..1.5 — 1 is the sample as it is.
  final double gain;

  /// 0 for none, 1..4: pressing this pad stops the group's other sounding pads.
  final int choke;
  final Quantise quantise;

  /// 0..1: how far the decks dip while this sounds. 1 is half way down.
  final double duck;

  /// Where in the sample the pad starts, and ends (null: its end).
  final Duration trimIn;
  final Duration? trimOut;

  /// A key of the desk's own for this pad ('F3', 'KP7'), over the bank's own map.
  final String? key;

  PadSpec copyWith({
    int? sampleId,
    String? name,
    PadColour? colour,
    PadMode? mode,
    double? gain,
    int? choke,
    Quantise? quantise,
    double? duck,
    Duration? trimIn,
    Duration? trimOut,
    bool clearTrimOut = false,
    String? key,
    bool clearKey = false,
  }) =>
      PadSpec(
        sampleId: sampleId ?? this.sampleId,
        name: name ?? this.name,
        colour: colour ?? this.colour,
        mode: mode ?? this.mode,
        gain: gain ?? this.gain,
        choke: choke ?? this.choke,
        quantise: quantise ?? this.quantise,
        duck: duck ?? this.duck,
        trimIn: trimIn ?? this.trimIn,
        trimOut: clearTrimOut ? null : (trimOut ?? this.trimOut),
        key: clearKey ? null : (key ?? this.key),
      );

  Map<String, dynamic> toJson() => {
        'sample': sampleId,
        'name': name,
        'colour': colour.name,
        'mode': mode.name,
        'gain': gain,
        'choke': choke,
        'quantise': quantise.name,
        'duck': duck,
        'in_ms': trimIn.inMilliseconds,
        if (trimOut != null) 'out_ms': trimOut!.inMilliseconds,
        if (key != null) 'key': key,
      };

  factory PadSpec.fromJson(Map<String, dynamic> j) => PadSpec(
        sampleId: (j['sample'] as num).toInt(),
        name: j['name'] as String? ?? '',
        colour: PadColour.parse(j['colour'] as String?),
        mode: PadMode.parse(j['mode'] as String?),
        gain: ((j['gain'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.5),
        choke: ((j['choke'] as num?)?.toInt() ?? 0).clamp(0, 4),
        quantise: Quantise.parse(j['quantise'] as String?),
        duck: ((j['duck'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
        trimIn: Duration(milliseconds: (j['in_ms'] as num?)?.toInt() ?? 0),
        trimOut: j['out_ms'] == null ? null : Duration(milliseconds: (j['out_ms'] as num).toInt()),
        key: j['key'] as String?,
      );

  @override
  String toString() => 'Pad($name #$sampleId ${mode.label})';
}

/// A page of pads.
class Bank {
  Bank({required this.name, List<PadSpec?>? pads}) : pads = List<PadSpec?>.filled(size, null) {
    if (pads != null) {
      for (var i = 0; i < size && i < pads.length; i++) {
        this.pads[i] = pads[i];
      }
    }
  }

  /// Four rows of four.
  static const size = 16;
  static const across = 4;

  String name;
  final List<PadSpec?> pads;

  bool get isEmpty => pads.every((p) => p == null);

  Map<String, dynamic> toJson() => {
        'name': name,
        'pads': [for (final p in pads) p?.toJson()],
      };

  factory Bank.fromJson(Map<String, dynamic> j) => Bank(
        name: j['name'] as String? ?? '',
        pads: [
          for (final p in (j['pads'] as List? ?? const []))
            p == null ? null : PadSpec.fromJson(p as Map<String, dynamic>)
        ],
      );
}

/// A row of one bank pinned under the decks.
class StripSpec {
  const StripSpec({required this.bank, required this.row});
  final int bank, row;

  Map<String, dynamic> toJson() => {'bank': bank, 'row': row};
  factory StripSpec.fromJson(Map<String, dynamic> j) =>
      StripSpec(bank: (j['bank'] as num?)?.toInt() ?? 0, row: (j['row'] as num?)?.toInt() ?? 0);
}

/// The whole board: its banks, its level, and what is pinned.
class BoardDoc {
  BoardDoc({required this.banks, this.rev = 0, this.level = 0.8, this.strip});

  /// A, B, C, D.
  static const bankCount = 4;
  static const bankNames = ['A', 'B', 'C', 'D'];

  int rev;

  /// The server's revision this copy came from, where it came from one.
  int? serverRev;
  final List<Bank> banks;

  /// The board's own fader, 0..1.
  double level;
  StripSpec? strip;

  /// Four empty banks.
  factory BoardDoc.empty() => BoardDoc(banks: [for (final n in bankNames) Bank(name: n)]);

  PadSpec? pad(int bank, int pad) =>
      bank < 0 || bank >= banks.length || pad < 0 || pad >= Bank.size ? null : banks[bank].pads[pad];

  /// Every pad there is, with where it is.
  Iterable<({int bank, int pad, PadSpec spec})> get allPads sync* {
    for (var b = 0; b < banks.length; b++) {
      for (var p = 0; p < Bank.size; p++) {
        final s = banks[b].pads[p];
        if (s != null) yield (bank: b, pad: p, spec: s);
      }
    }
  }

  Map<String, dynamic> toJson() => {
        'rev': rev,
        if (serverRev != null) 'server_rev': serverRev,
        'level': level,
        if (strip != null) 'strip': strip!.toJson(),
        'banks': [for (final b in banks) b.toJson()],
      };

  factory BoardDoc.fromJson(Map<String, dynamic> j) {
    final banks = [
      for (final b in (j['banks'] as List? ?? const [])) Bank.fromJson(b as Map<String, dynamic>)
    ];
    while (banks.length < bankCount) {
      banks.add(Bank(name: bankNames[banks.length]));
    }
    return BoardDoc(
      banks: banks.take(bankCount).toList(),
      rev: (j['rev'] as num?)?.toInt() ?? 0,
      level: ((j['level'] as num?)?.toDouble() ?? 0.8).clamp(0.0, 1.0),
      strip: j['strip'] == null ? null : StripSpec.fromJson(j['strip'] as Map<String, dynamic>),
    )..serverRev = (j['server_rev'] as num?)?.toInt();
  }
}
