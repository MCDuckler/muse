// What goes with what, by character rather than pair by pair.
//
// Every scene and every style of one (a dancer's art, a flock's look, a face of the
// words) has a character — what it does to whatever is under it — and every
// background has one too. A handful of rules say how a character goes on a
// background's character; a few exceptions say otherwise for one thing on one
// background. So a new style follows the rules by its character alone, and the
// table a person reads is twelve sentences, not two hundred cells.
//
//   lights in the dark   bright marks on black: the glyphs, the trails, the birds,
//                        the words — anything shows round them;
//   ink on paper         a bright page with the figure on it: the plain dancers, the
//                        silhouettes, the flock in ink — the page hides what is under;
//   full frame           a pattern edge to edge: the shapes, the fluid, the floor —
//                        two of them fight;
//   a world of its own   a whole picture with its own setting: the edit, the sky, the
//                        room, the grid of viewports — it wants nothing under it.
//
//   glow                 dark and slow: the wash, the pulse;
//   busy                 moving and full of colour: MilkDrop, a field;
//   a picture            something to recognise: the camera, the cover.
//
// Black is nothing: a scene on black is drawn as it is, always.
//
// Which rule answers, in order: your exception for this thing on this background,
// the shipped exception, your rule for the two characters, the shipped rule.
// See show_pool.dart (ShowPool.answer) and the plan, §5.3.
import 'show_rig.dart';

/// What a scene or a style does to whatever is under it.
enum Character {
  lights('Lights in the dark', 'bright marks on black — the glyphs, the trails, the birds, the words: anything shows round them'),
  paper('Ink on paper', 'a bright page with the figure on it — the plain dancers, the silhouettes: the page hides what is under'),
  full('Full frame', 'a pattern from edge to edge — the shapes, the fluid, the floor: two of them fight'),
  world('A world of its own', 'a whole picture with its own setting — the edit, the sky, the room: it wants nothing under it');

  const Character(this.title, this.words);
  final String title, words;
}

/// What a background is like, for the rules.
enum Backdrop {
  glow('Glow', 'dark and slow: the wash, the pulse'),
  busy('Busy', 'moving and full of colour: MilkDrop, a field'),
  picture('A picture', 'something to recognise: the camera, the cover');

  const Backdrop(this.title, this.words);
  final String title, words;
}

/// Where an answer came from, most particular first.
enum RuleFrom {
  /// On black: as drawn, always.
  black,

  /// The hands' exception for this thing on this background.
  yourException,

  /// One that came with the app (with its reason).
  exception,

  /// The hands' rule for the two characters.
  yourRule,

  /// The rule that came with the app.
  rule,
}

/// A rule for a pair, a pair of characters or an exception: never, or a way of
/// blending and how the figures go. [follow] is an exception of the hands' that says
/// "as the rule says" — it silences a shipped exception.
class ComboRule {
  const ComboRule({this.off = false, this.ground, this.figure, this.follow = false});

  /// The two never go together (the director passes the pair by; one put on by hand
  /// goes onto black).
  final bool off;

  /// The blend for the pair, where the rule has one.
  final GroundMode? ground;
  final FigureMode? figure;

  /// No answer of its own: the rule for the characters decides (over a shipped
  /// exception).
  final bool follow;

  static const never = ComboRule(off: true);
  static const contrast = ComboRule(ground: GroundMode.contrast);
  static const over = ComboRule(ground: GroundMode.over);
  static const asTheRule = ComboRule(follow: true);

  Map<String, dynamic> toJson() => {
        if (off) 'off': true,
        if (ground != null) 'ground': ground!.name,
        if (figure != null) 'figure': figure!.name,
        if (follow) 'follow': true,
      };

  factory ComboRule.fromJson(Map<String, dynamic> j) => ComboRule(
        off: j['off'] == true,
        ground: j['ground'] is String ? GroundMode.values.where((g) => g.name == j['ground']).firstOrNull : null,
        figure: j['figure'] is String ? FigureMode.values.where((f) => f.name == j['figure']).firstOrNull : null,
        follow: j['follow'] == true,
      );

  @override
  bool operator ==(Object other) => other is ComboRule && other.off == off && other.ground == ground && other.figure == figure && other.follow == follow;
  @override
  int get hashCode => Object.hash(off, ground, figure, follow);
}

/// The answer for a figure on a ground: the rule, where it came from, by which key
/// (an exception's pair key, or the rule's `character|backdrop`), and the two
/// characters it was looked up by.
class RuleAnswer {
  const RuleAnswer({required this.rule, required this.from, required this.character, this.backdrop, this.key});
  final ComboRule rule;
  final RuleFrom from;
  final Character character;
  final Backdrop? backdrop;
  final String? key;

  bool get never => rule.off;

  /// The reason that came with a shipped answer, where it has one.
  String? get why => switch (from) {
        RuleFrom.exception => shippedExceptionWhy[key],
        RuleFrom.rule => shippedRuleWhy[key],
        RuleFrom.black => 'on black a scene is drawn as it is',
        _ => null,
      };
}

/// How often a thing comes on by itself (the director's, a figure's clock's, the
/// backgrounds' rotation): never, less, as much as any, more.
enum Often {
  never('OFF', 'switched off: gone everywhere until switched back on (ON/OFF)', 0),
  rarely('RARELY', 'less than the others', 0.4),
  normal('NORMAL', 'as often as any', 1),
  often('OFTEN', 'more than the others', 2);

  const Often(this.word, this.words, this.lean);
  final String word, words;
  final double lean;

  static Often ofLean(double lean) => lean < 0.7 ? rarely : (lean > 1.5 ? often : normal);
}

/// The key a thing's character (and how often) is kept by: `figure.<kind>`,
/// `figure.<kind>.style.<name>`, `ground.<kind>`.
String figureKey(Figure kind, [String? style]) => style == null ? 'figure.${kind.name}' : 'figure.${kind.name}.style.$style';
String groundKey(Ground g) => 'ground.${g.name}';

/// The characters as shipped, by thing key; a style without one is its figure's,
/// a figure without one is lights in the dark.
const shippedCharacters = <String, Character>{
  'figure.dancers': Character.lights,
  'figure.birds': Character.lights,
  'figure.words': Character.lights,
  'figure.turntable': Character.lights,
  'figure.flash': Character.lights,
  'figure.kinetic': Character.full,
  'figure.blocks': Character.full,
  'figure.glide': Character.full,
  'figure.fluid': Character.full,
  'figure.veins': Character.full,
  'figure.field': Character.full,
  'figure.room': Character.world,
  'figure.meme': Character.world,
  // The dancers' styles that are not lights in the dark.
  'figure.dancers.style.plain': Character.paper,
  'figure.dancers.style.mono': Character.paper,
  'figure.dancers.style.fluid': Character.full,
  'figure.dancers.style.disco': Character.full,
  'figure.dancers.style.viewports': Character.world,
  // The flock's.
  'figure.birds.style.ink': Character.paper,
  'figure.birds.style.sky': Character.world,
};

/// The backgrounds' characters as shipped. Black has none: it is nothing.
const shippedBackdrops = <Ground, Backdrop>{
  Ground.wash: Backdrop.glow,
  Ground.pulse: Backdrop.glow,
  Ground.milk: Backdrop.busy,
  Ground.field: Backdrop.busy,
  Ground.camera: Backdrop.picture,
  Ground.cover: Backdrop.picture,
};

String ruleKey(Character c, Backdrop b) => '${c.name}|${b.name}';

/// The twelve rules as shipped.
const shippedRules = <String, ComboRule>{
  'lights|glow': ComboRule(ground: GroundMode.add, figure: FigureMode.over),
  'lights|busy': ComboRule(ground: GroundMode.contrast, figure: FigureMode.over),
  'lights|picture': ComboRule(ground: GroundMode.dim, figure: FigureMode.over),
  'paper|glow': ComboRule(ground: GroundMode.over),
  'paper|busy': ComboRule.never,
  'paper|picture': ComboRule(ground: GroundMode.over),
  'full|glow': ComboRule(ground: GroundMode.add),
  'full|busy': ComboRule(ground: GroundMode.contrast),
  'full|picture': ComboRule.never,
  'world|glow': ComboRule.never,
  'world|busy': ComboRule.never,
  'world|picture': ComboRule.never,
};

/// The ways each shipped rule may blend, the first its own: the director takes one
/// per scene, background and record (a session's own), so the same pair is not
/// always the same picture. A rule of the hands' has its one way.
const shippedWays = <String, List<GroundMode>>{
  'lights|glow': [GroundMode.add, GroundMode.screen],
  'lights|busy': [GroundMode.contrast, GroundMode.screen, GroundMode.add],
  'lights|picture': [GroundMode.dim, GroundMode.window, GroundMode.add],
  'paper|glow': [GroundMode.over],
  'paper|picture': [GroundMode.over, GroundMode.keyhole],
  'full|glow': [GroundMode.add, GroundMode.screen],
  'full|busy': [GroundMode.contrast, GroundMode.screen, GroundMode.dim],
};

const shippedRuleWhy = <String, String>{
  'lights|glow': 'the marks\' light added over the glow, the figures as drawn',
  'lights|busy': 'the booth\'s way: where the two agree is dark, so the marks cut through; the figures as drawn',
  'lights|picture': 'the picture at a third under the marks, so both read',
  'paper|glow': 'the page covers the glow: as drawn',
  'paper|busy': 'a bright page over a busy picture inverts it or hides it',
  'paper|picture': 'the page covers the picture: as drawn',
  'full|glow': 'the pattern\'s light added over the glow',
  'full|busy': 'the booth\'s way: the difference of the two',
  'full|picture': 'two busy pictures over each other',
  'world|glow': 'a world of its own wants nothing under it',
  'world|busy': 'a world of its own wants nothing under it',
  'world|picture': 'a world of its own wants nothing under it',
};

/// The exceptions that came with the app: one thing on one background, by pair key
/// (show_pool.dart's comboKey).
const shippedExceptions = <String, ComboRule>{
  'figure.dancers.style.mono|ground.milk': ComboRule(ground: GroundMode.keyhole),
  'figure.dancers.style.fluid|ground.milk': ComboRule(ground: GroundMode.screen),
  'figure.fluid|ground.milk': ComboRule(ground: GroundMode.screen),
  'figure.veins|ground.milk': ComboRule(ground: GroundMode.screen),
};

const shippedExceptionWhy = <String, String>{
  'figure.dancers.style.mono|ground.milk': 'the silhouettes a window onto the preset, the rest black',
  'figure.dancers.style.fluid|ground.milk': 'screened, so neither the fluid nor the preset blows the other out',
  'figure.fluid|ground.milk': 'screened, so neither blows the other out',
  'figure.veins|ground.milk': 'screened, so neither blows the other out',
};
