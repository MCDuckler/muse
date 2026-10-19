// The SHOW page's rules, cards and catalogue (part of show_room.dart).
//
// One card per thing — a scene, a style of one, a background — with everything about
// it in one place: what it is (its character), how often it comes on by itself, what
// it goes with (an answer for every background, and where the answer came from),
// why it is on the stage now; opened by holding (or right-clicking) any chip, or
// from the EVERYTHING list. The RULES tab is the twelve rules — a character on a
// background's — and the exceptions, in words; every pair is still there, folded,
// for the whole picture at once. state/show/show_characters.dart has the model.
part of 'show_room.dart';

// ---------------------------------------------------------------- things
/// Something with a card: a scene (a look), a style of a figure, a background.
sealed class _Thing {
  const _Thing();
}

class _SceneThing extends _Thing {
  const _SceneThing(this.id);
  final String id;
}

class _StyleThing extends _Thing {
  const _StyleThing(this.kind, this.style);
  final Figure kind;
  final String style;
}

class _GroundThing extends _Thing {
  const _GroundThing(this.ground);
  final Ground ground;
}

/// The styles a figure's clock picks from, by name: the dancers' renderings, the
/// flock's looks, the words' faces.
List<String> _stylesOf(Figure f) => switch (f) {
      Figure.dancers => [for (final a in DanceArt.values) a.name],
      Figure.birds => [for (final l in FlockLook.values) l.name],
      Figure.words => [for (final w in WordsStyle.values) w.name],
      _ => const [],
    };

/// A figure's name, as its scene is called.
String _figureWord(Figure k, SceneBook? book) {
  if (k == Figure.room) return 'Echo · Fold';
  final s = book?.scenes.values.where((s) => s.look.rig.figure.kind == k).firstOrNull;
  return s?.name ?? (k.name[0].toUpperCase() + k.name.substring(1));
}

/// The scene a figure is drawn by (for a style's card: to put it on).
String? _sceneOfFigure(Figure k, SceneBook book) => book.scenes.values.where((s) => s.look.rig.figure.kind == k).firstOrNull?.id;

String _thingName(_Thing t, SceneBook book) => switch (t) {
      _SceneThing(:final id) => book[id]?.name ?? id,
      _StyleThing(:final kind, :final style) => '${_figureWord(kind, book)} · $style',
      _GroundThing(:final ground) => _groundWord(ground),
    };

/// The figure the rules look a thing up by (none for a background).
RigFigure? _figureOf(_Thing t, SceneBook book) => switch (t) {
      _SceneThing(:final id) => book[id] == null ? null : RigFigure(kind: book[id]!.look.rig.figure.kind),
      _StyleThing(:final kind, :final style) => RigFigure(kind: kind, style: style),
      _GroundThing() => null,
    };

/// The key a thing's "how often" is kept by (none for black, which is not rotated).
String? _oftenKey(_Thing t) => switch (t) {
      _SceneThing(:final id) => 'look.$id',
      _StyleThing(:final kind, :final style) => 'style.${kind.name}.$style',
      _GroundThing(:final ground) => ground == Ground.black ? null : 'ground.${ground.name}',
    };

/// The key a thing's character is kept by.
String _characterKey(_Thing t, SceneBook book) => switch (t) {
      _SceneThing() => figureKey(_figureOf(t, book)?.kind ?? Figure.none),
      _StyleThing(:final kind, :final style) => figureKey(kind, style),
      _GroundThing(:final ground) => groundKey(ground),
    };

/// A thing's picture: its thumbnail, or a swatch.
Widget _thingPicture(_Thing t, {double w = 64, double h = 36}) {
  final (thumb, colour) = switch (t) {
    _SceneThing(:final id) => (thumbOf(id), Console.ground),
    _StyleThing(:final kind) => (kind == Figure.dancers ? thumbOf('dance-art') : (kind == Figure.birds ? thumbOf('flock') : thumbOf('lyrics')), Console.ground),
    _GroundThing(:final ground) => switch (ground) {
        Ground.milk => ('assets/show/thumbs/milk.webp', const Color(0xff402060)),
        Ground.field => ('assets/show/thumbs/drift.webp', const Color(0xff101418)),
        Ground.pulse => ('assets/show/thumbs/pulse-grid.webp', const Color(0xff101418)),
        Ground.black => (null, const Color(0xff050505)),
        Ground.wash => (null, const Color(0xff2a2238)),
        Ground.camera => (null, const Color(0xff203028)),
        Ground.cover => (null, const Color(0xff303040)),
      },
  };
  return ClipRRect(
    borderRadius: BorderRadius.circular(3),
    child: SizedBox(
      width: w,
      height: h,
      child: thumb != null ? Image.asset(thumb, fit: BoxFit.cover, errorBuilder: (c, _, __) => ColoredBox(color: colour)) : ColoredBox(color: colour),
    ),
  );
}

// ---------------------------------------------------------------- words
/// A rule in words: `never`, `contrast`, `contrast, figures on top`.
String _wayWords(ComboRule r) => r.off
    ? 'never'
    : [
        (r.ground ?? GroundMode.over).name,
        if (r.figure == FigureMode.over) 'figures on top',
      ].join(', ');

String _fromWords(RuleFrom f) => switch (f) {
      RuleFrom.black => 'on black',
      RuleFrom.yourException => 'your exception',
      RuleFrom.exception => 'an exception',
      RuleFrom.yourRule => 'your rule',
      RuleFrom.rule => 'the rule',
    };

/// An answer in words: what holds, and where it came from, and why.
String _answerWords(RuleAnswer a) {
  if (a.from == RuleFrom.black) return 'as drawn — on black every scene is';
  final rule = a.from == RuleFrom.rule || a.from == RuleFrom.yourRule ? ' for ${a.character.title.toLowerCase()} on ${a.backdrop!.title.toLowerCase()}' : '';
  final why = a.why;
  return '${_wayWords(a.rule)} — ${_fromWords(a.from)}$rule${why != null ? ': $why' : ''}';
}

/// The things of a character, in words: `Kinetic, Blocks, Dancer: plain, mono`.
List<String> _membersOf(Character c, ShowPool pool, SceneBook book) {
  final out = <String>[];
  final seen = <Figure>{};
  for (final s in book.scenes.values.toList()..sort((a, b) => a.name.compareTo(b.name))) {
    final f = s.look.rig.figure;
    if (f.kind == Figure.none || !seen.add(f.kind)) continue;
    final name = f.kind == Figure.room ? 'Echo · Fold' : s.name;
    final styles = _stylesOf(f.kind);
    if (styles.isEmpty) {
      if (pool.characterOf(RigFigure(kind: f.kind)) == c) out.add(name);
      continue;
    }
    final mine = [
      for (final st in styles)
        if (pool.characterOf(RigFigure(kind: f.kind, style: st)) == c) st
    ];
    if (mine.length == styles.length) {
      out.add('$name (every style)');
    } else if (mine.isNotEmpty) {
      out.add('$name: ${mine.join(', ')}');
    }
  }
  return out;
}

/// The backgrounds of a character, in words.
List<String> _groundsOf(Backdrop b, ShowPool pool) => [
      for (final g in _ruleGrounds)
        if (g != Ground.black && pool.backdropOf(g) == b) _groundWord(g)
    ];

const _ruleGrounds = [Ground.black, Ground.wash, Ground.milk, Ground.field, Ground.camera, Ground.cover, Ground.pulse];

/// The ground the hands put under a scene to try a pair.
RigGround _groundToTry(Ground g) => switch (g) {
      Ground.black => RigGround.black,
      Ground.wash => const RigGround(kind: Ground.wash),
      Ground.milk => RigGround.milk,
      Ground.field => const RigGround(kind: Ground.field, field: 'drift', dim: 0.6),
      Ground.camera => const RigGround(kind: Ground.camera, dim: 0.8),
      Ground.cover => const RigGround(kind: Ground.cover, dim: 0.6),
      Ground.pulse => const RigGround(kind: Ground.pulse, field: 'grid'),
    };

/// The colour a source is marked in: yours in the accent, an exception in the
/// second, a rule in the plain line.
Color _fromColour(RuleFrom f) => switch (f) {
      RuleFrom.yourException || RuleFrom.yourRule => Console.a,
      RuleFrom.exception => Console.b,
      _ => Console.line,
    };

// ---------------------------------------------------------------- menus
RelativeRect _under(BuildContext context) {
  final box = context.findRenderObject() as RenderBox;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  return RelativeRect.fromRect(
    Rect.fromPoints(box.localToGlobal(Offset.zero, ancestor: overlay), box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay)),
    Offset.zero & overlay.size,
  );
}

Widget _menuLine(IconData icon, String words, {bool lit = false}) => Row(children: [
      Icon(icon, size: 16, color: lit ? Console.a : Console.quiet),
      const SizedBox(width: 8),
      Expanded(child: Text(words, style: TextStyle(fontSize: 12, color: lit ? Console.a : Console.ink))),
    ]);

List<PopupMenuEntry<Object>> _wayItems(ComboRule now) => [
      PopupMenuItem<Object>(enabled: false, height: 24, child: Text('BLENDED AS…', style: Console.label(8))),
      for (final m in GroundMode.values)
        PopupMenuItem<Object>(
          value: m,
          height: 34,
          child: Row(children: [
            ClipRRect(borderRadius: BorderRadius.circular(3), child: _BlendSwatch(m, width: 40, height: 22)),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${m.name} — ${_modeWords[m]}',
                  style: TextStyle(fontSize: 11, color: !now.off && now.ground == m ? Console.a : Console.ink), maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          ]),
        ),
    ];

/// The menu on a rule: a character on a background's.
Future<void> _ruleMenu(BuildContext context, ShowEngine show, Character c, Backdrop b) async {
  final pool = show.pool;
  final (now, mine) = pool.ruleOf(c, b);
  final shipped = shippedRules[ruleKey(c, b)] ?? ComboRule.contrast;
  final onTop = !now.off && now.figure == FigureMode.over;
  final picked = await showMenu<Object>(
    context: context,
    position: _under(context),
    color: Console.panel,
    constraints: const BoxConstraints(minWidth: 320, maxWidth: 400),
    items: [
      PopupMenuItem<Object>(
        enabled: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('${c.title} on ${b.title.toLowerCase()} backgrounds', style: TextStyle(fontSize: 13, color: Console.ink, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text('${_wayWords(now)}${mine ? ' (yours; shipped: ${_wayWords(shipped)})' : ' — ${shippedRuleWhy[ruleKey(c, b)] ?? ''}'}',
              style: TextStyle(fontSize: 11, color: mine ? Console.a : Console.quiet, height: 1.3)),
          Text('For every ${c.title.toLowerCase()} thing on ${_groundsOf(b, pool).join(', ')}; an exception still wins.',
              style: TextStyle(fontSize: 10, color: Console.faint, height: 1.3)),
        ]),
      ),
      const PopupMenuDivider(height: 6),
      if (mine) PopupMenuItem<Object>(value: 'shipped', child: _menuLine(Icons.undo, 'As shipped again — ${_wayWords(shipped)}')),
      if (!now.off) PopupMenuItem<Object>(value: 'never', child: _menuLine(Icons.block, 'Never together')),
      ..._wayItems(now),
      const PopupMenuDivider(height: 6),
      PopupMenuItem<Object>(
          value: 'top', child: _menuLine(onTop ? Icons.check_box : Icons.check_box_outline_blank, 'The figures on top, as drawn', lit: onTop)),
    ],
  );
  if (picked == null) return;
  feel(Feel.pick);
  if (picked is GroundMode) return show.setPool(pool.withRule(c, b, ComboRule(ground: picked, figure: now.off ? null : now.figure)));
  switch (picked) {
    case 'shipped':
      show.setPool(pool.withRule(c, b, null));
    case 'never':
      show.setPool(pool.withRule(c, b, ComboRule.never));
    case 'top':
      show.setPool(pool.withRule(c, b, ComboRule(ground: now.off ? GroundMode.contrast : now.ground, figure: onTop ? FigureMode.same : FigureMode.over)));
  }
}

/// The menu on one thing on one background: its answer, and an exception of its own.
Future<void> _pairMenu(BuildContext context, ShowEngine show, SceneBook book, _Thing thing, Ground g) async {
  final figure = _figureOf(thing, book);
  if (figure == null) return;
  final pool = show.pool;
  final a = pool.answer(figure, g);
  final name = _thingName(thing, book);
  if (a.from == RuleFrom.black) return;
  final key = ShowPool.comboKey(figure, g);
  final silenced = pool.combos[key]?.follow ?? false;
  final shippedException = shippedExceptions[key];
  final (rule, _) = pool.ruleOf(a.character, a.backdrop!);
  final now = a.rule;
  final onTop = !now.off && now.figure == FigureMode.over;
  final picked = await showMenu<Object>(
    context: context,
    position: _under(context),
    color: Console.panel,
    constraints: const BoxConstraints(minWidth: 320, maxWidth: 400),
    items: [
      PopupMenuItem<Object>(
        enabled: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('$name on ${_groundWord(g)}', style: TextStyle(fontSize: 13, color: Console.ink, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(_answerWords(a), style: TextStyle(fontSize: 11, color: a.from == RuleFrom.yourException ? Console.a : Console.quiet, height: 1.3)),
          if (silenced && shippedException != null)
            Text('the shipped exception (${_wayWords(shippedException)}) is off for it', style: TextStyle(fontSize: 10, color: Console.faint, height: 1.3)),
        ]),
      ),
      const PopupMenuDivider(height: 6),
      if (a.from == RuleFrom.yourException || silenced)
        PopupMenuItem<Object>(
            value: 'clear',
            child: _menuLine(Icons.undo,
                'No exception of yours — ${shippedException != null ? 'the shipped exception, ${_wayWords(shippedException)}' : 'the rule, ${_wayWords(rule)}'}')),
      if (a.from == RuleFrom.exception) PopupMenuItem<Object>(value: 'follow', child: _menuLine(Icons.rule, 'Follow the rule instead — ${_wayWords(rule)}')),
      if (!now.off) PopupMenuItem<Object>(value: 'never', child: _menuLine(Icons.block, 'Never on ${_groundWord(g)}')),
      ..._wayItems(now),
      const PopupMenuDivider(height: 6),
      PopupMenuItem<Object>(
          value: 'top', child: _menuLine(onTop ? Icons.check_box : Icons.check_box_outline_blank, 'The figures on top, as drawn', lit: onTop)),
      PopupMenuItem<Object>(
          value: 'rule', child: _menuLine(Icons.tune, 'The rule for ${a.character.title.toLowerCase()} on ${a.backdrop!.title.toLowerCase()}…')),
      PopupMenuItem<Object>(value: 'try', child: _menuLine(Icons.play_arrow, 'Put it on the stage on ${_groundWord(g)}')),
    ],
  );
  if (picked == null || !context.mounted) return;
  feel(Feel.pick);
  if (picked is GroundMode) return show.setPool(pool.withCombo(key, ComboRule(ground: picked, figure: now.off ? null : now.figure)));
  switch (picked) {
    case 'clear':
      show.setPool(pool.withCombo(key, null));
    case 'follow':
      show.setPool(pool.withCombo(key, ComboRule.asTheRule));
    case 'never':
      show.setPool(pool.withCombo(key, ComboRule.never));
    case 'top':
      show.setPool(pool.withCombo(key, ComboRule(ground: now.off ? GroundMode.contrast : now.ground, figure: onTop ? FigureMode.same : FigureMode.over)));
    case 'rule':
      await _ruleMenu(context, show, a.character, a.backdrop!);
    case 'try':
      _putOn(show, book, thing, ground: g);
  }
}

/// A thing put on the stage, at once: a scene (on [ground], if given), a style with
/// its scene, a background under whatever is on.
void _putOn(ShowEngine show, SceneBook book, _Thing t, {Ground? ground}) {
  if (ground != null) {
    show.setGround(_groundToTry(ground));
    show.lock(RigSlot.blend, false);
  }
  switch (t) {
    case _SceneThing(:final id):
      show.launch(id, at: Quantise.now);
    case _StyleThing(:final kind, :final style):
      show.setStyle(style, forKind: kind);
      final id = _sceneOfFigure(kind, book);
      if (id != null) show.launch(id, at: Quantise.now);
    case _GroundThing(ground: final g):
      show.setGround(_groundToTry(g));
  }
}

// ---------------------------------------------------------------- the card
Future<void> _openCard(BuildContext context, ShowEngine show, SceneBook book, _Thing thing) => showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _ThingCard(show: show, book: book, thing: thing),
    );

class _ThingCard extends StatelessWidget {
  const _ThingCard({required this.show, required this.book, required this.thing});
  final ShowEngine show;
  final SceneBook book;
  final _Thing thing;

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: Console.panel,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: Console.line)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListenableBuilder(
            listenable: show,
            builder: (context, _) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: _body(context)),
            ),
          ),
        ),
      );

  List<Widget> _body(BuildContext context) {
    final pool = show.pool;
    final name = _thingName(thing, book);
    final figure = _figureOf(thing, book);
    final whole = thing is _SceneThing && figure?.kind == Figure.none;
    final kindWords = switch (thing) {
      _SceneThing(:final id) => 'a scene${book[id] != null ? ' · ${_familyWord(_familyOf(book[id]!)).toLowerCase()}' : ''}',
      _StyleThing(:final kind) => 'a style of the ${_figureWord(kind, book)} scene',
      _GroundThing() => 'a background',
    };
    final oftenKey = _oftenKey(thing);
    final who = switch (thing) {
      _SceneThing() => 'the director',
      _StyleThing(:final kind) => 'the ${_figureWord(kind, book)}\'s clock',
      _GroundThing() => 'the director\'s backgrounds',
    };
    Widget head(String word, [String? tip]) => Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 6),
          child: Row(children: [
            Text(word, style: Console.label(9, color: Console.ink)),
            if (tip != null) ...[
              const SizedBox(width: 8),
              Expanded(child: Text(tip, style: TextStyle(fontSize: 10, color: Console.faint), overflow: TextOverflow.ellipsis))
            ],
          ]),
        );
    final out = <Widget>[
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _thingPicture(thing, w: 112, h: 63),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: Mag.title(18, color: Console.ink)),
            const SizedBox(height: 2),
            Text(kindWords, style: TextStyle(fontSize: 11, color: Console.quiet)),
            const SizedBox(height: 8),
            Wrap(spacing: 4, runSpacing: 4, children: [
              IntrinsicWidth(
                child: Pad(
                  label: 'PUT ON THE STAGE',
                  height: 24,
                  colour: Console.a,
                  tooltip: 'At once, as it is',
                  onTap: () => _putOn(show, book, thing),
                ),
              ),
            ]),
          ]),
        ),
        Pad(icon: Icons.close, width: 28, height: 28, colour: Console.quiet, tooltip: 'Close', onTap: () => Navigator.of(context).pop()),
      ]),
    ];

    // What it is.
    if (whole) {
      out
        ..add(head('WHAT IT IS'))
        ..add(Text('Its own whole picture: no background under it, so no character and no rules.', style: TextStyle(fontSize: 11, color: Console.quiet)));
    } else if (thing is _GroundThing) {
      final g = (thing as _GroundThing).ground;
      if (g == Ground.black) {
        out
          ..add(head('WHAT IT IS'))
          ..add(Text('Nothing: every scene on black is drawn as it is.', style: TextStyle(fontSize: 11, color: Console.quiet)));
      } else {
        final b = pool.backdropOf(g)!;
        final mine = pool.characters.containsKey(groundKey(g));
        out
          ..add(head('WHAT IT IS', mine ? 'yours (shipped: ${shippedBackdrops[g]?.title.toLowerCase()})' : 'as shipped'))
          ..add(Wrap(children: [
            for (final x in Backdrop.values)
              _Word(
                label: x.title.toUpperCase(),
                lit: x == b,
                tooltip: x.words,
                onTap: () => show.setPool(pool.withCharacter(groundKey(g), x == shippedBackdrops[g] ? null : x.name)),
              ),
          ]))
          ..add(Text(b.words, style: TextStyle(fontSize: 10, color: Console.faint)));
      }
    } else {
      final key = _characterKey(thing, book);
      final (c, own) = pool.characterOfKey(key);
      final mine = pool.characters.containsKey(key);
      final inherited = thing is _StyleThing && !own;
      out
        ..add(head(
            'WHAT IT IS',
            mine
                ? 'yours — every pairing follows it'
                : (inherited ? 'as its scene (${_figureWord((thing as _StyleThing).kind, book)})' : 'as shipped — every pairing follows it')))
        ..add(Wrap(children: [
          for (final x in Character.values)
            _Word(
              label: x.title.toUpperCase(),
              lit: x == c,
              tooltip: x.words,
              onTap: () => show.setPool(pool.withCharacter(key, x == shippedCharacters[key] ? null : x.name)),
            ),
          if (mine) _Word(label: 'AS SHIPPED', lit: false, tooltip: 'Its character as it came', onTap: () => show.setPool(pool.withCharacter(key, null))),
        ]))
        ..add(Text(c.words, style: TextStyle(fontSize: 10, color: Console.faint)));
    }

    // How often.
    if (oftenKey != null) {
      final o = pool.oftenOf(oftenKey);
      out
        ..add(head('HOW OFTEN', 'how often $who puts it on by itself — by hand it always goes'))
        ..add(Wrap(children: [
          for (final x in Often.values) _Word(label: x.word, lit: x == o, tooltip: x.words, onTap: () => show.setPool(pool.withOften(oftenKey, x))),
        ]));
    }

    // What it goes with.
    if (!whole && figure != null) {
      out
        ..add(head('GOES WITH', 'tap a background: its answer, an exception of its own'))
        ..add(Wrap(spacing: 6, runSpacing: 6, children: [
          for (final g in _ruleGrounds) _GoesTile(show: show, book: book, thing: thing, ground: g),
        ]));
      final styles = thing is _SceneThing ? _stylesOf(figure.kind) : const <String>[];
      if (styles.isNotEmpty) {
        out
          ..add(head('ITS STYLES', 'each has a card of its own; one without a character of its own is this scene\'s'))
          ..add(Wrap(children: [
            for (final st in styles)
              _Word(
                label: st.toUpperCase(),
                lit: false,
                off: !pool.styleOn(figure.kind, st),
                tooltip: '${pool.characterOf(RigFigure(kind: figure.kind, style: st)).title} — its card',
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_openCard(context, show, book, _StyleThing(figure.kind, st)));
                },
              ),
          ]));
      }
    } else if (thing is _GroundThing && (thing as _GroundThing).ground != Ground.black) {
      final g = (thing as _GroundThing).ground;
      final b = pool.backdropOf(g)!;
      out.add(head('UNDER IT', 'the rules for ${b.title.toLowerCase()} backgrounds; tap one to change it for all of them'));
      for (final c in Character.values) {
        final (r, mine) = pool.ruleOf(c, b);
        out.add(Builder(
          builder: (context) => InkWell(
            onTap: () => _ruleMenu(context, show, c, b),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                SizedBox(width: 150, child: Text(c.title, style: TextStyle(fontSize: 12, color: Console.ink))),
                _RuleFace(rule: r, mine: mine),
                const SizedBox(width: 8),
                Expanded(child: Text(_wayWords(r), style: TextStyle(fontSize: 11, color: mine ? Console.a : Console.quiet))),
              ]),
            ),
          ),
        ));
      }
      final exceptions = [
        for (final e in {...shippedExceptions, ...pool.combos}.entries)
          if (e.key.endsWith('|ground.${g.name}')) e
      ];
      if (exceptions.isNotEmpty) {
        out.add(head('EXCEPTIONS ON IT'));
        for (final e in exceptions) {
          out.add(Text('${_keyWords(e.key)}: ${e.value.follow ? 'as the rule says' : _wayWords(e.value)}${pool.combos.containsKey(e.key) ? ' (yours)' : ''}',
              style: TextStyle(fontSize: 11, color: Console.quiet)));
        }
      }
    }

    // Why it is on now.
    final why = _whyNow(show, book, thing);
    if (why != null) {
      out
        ..add(head('ON THE STAGE NOW'))
        ..add(Text(why, style: TextStyle(fontSize: 11, color: Console.ink)));
    }
    return out;
  }
}

/// Why a thing is on the stage now, in words; null where it is not.
String? _whyNow(ShowEngine show, SceneBook book, _Thing t) {
  final st = show.state;
  final rig = st.rig;
  switch (t) {
    case _SceneThing(:final id):
      if (st.scene != id) return null;
      return _sceneWhy(show);
    case _StyleThing(:final kind, :final style):
      final now = ShowPool.lookupFigure(rig.figure);
      if (rig.figure.kind != kind || now.style != style) return null;
      return show.style == style && show.styleFor == kind ? 'Held by you (the style row): its clock leaves it.' : 'Its clock put it on for this section.';
    case _GroundThing(:final ground):
      if (rig.ground.kind != ground) return null;
      return _groundWhy(show, book);
  }
}

String _sceneWhy(ShowEngine show) {
  if (show.milkOnly) return 'MilkDrop alone, by you: the arrows step its presets.';
  if (show.sceneHeld) return 'Held by you: the director leaves it.';
  final d = show.director;
  final bars = d.barsOn;
  return '${d.why.isEmpty ? 'the director\'s' : 'The director: ${d.why}'} — on for $bars bar${bars == 1 ? '' : 's'}.';
}

String _groundWhy(ShowEngine show, SceneBook book) {
  final rig = show.state.rig;
  if (rig.figure.kind == Figure.none) return 'The scene\'s own: MilkDrop alone is its own picture.';
  if (show.locked(RigSlot.ground)) return 'Yours: the director leaves it.';
  final dg = show.director.ground;
  if (dg != null && rig.ground.kind == Ground.black && dg.kind != Ground.black) {
    final a = show.pool.answer(ShowPool.lookupFigure(rig.figure), dg.kind);
    if (a.never) return 'Black: ${_groundWord(dg.kind)} is the director\'s, but this scene never goes on it (${_fromWords(a.from)}).';
  }
  if (dg == null) return 'Black: no background is switched on for the director.';
  final bars = show.director.groundBars;
  return 'The director\'s — on for $bars bar${bars == 1 ? '' : 's'}; another may come on a phrase after ${ShowDirector.groundHoldBars}.';
}

/// One background in a card's GOES WITH: its answer as a picture and a word, its
/// source by its edge.
class _GoesTile extends StatelessWidget {
  const _GoesTile({required this.show, required this.book, required this.thing, required this.ground});
  final ShowEngine show;
  final SceneBook book;
  final _Thing thing;
  final Ground ground;

  @override
  Widget build(BuildContext context) {
    final figure = _figureOf(thing, book)!;
    final a = show.pool.answer(figure, ground);
    final edge = _fromColour(a.from);
    final rigNow = show.state.rig;
    final onStage = rigNow.ground.kind == ground &&
        rigNow.figure.kind == figure.kind &&
        (figure.style == null || ShowPool.lookupFigure(rigNow.figure).style == figure.style);
    return Tooltip(
      message: '${_groundWord(ground)}: ${_answerWords(a)}',
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: () => _pairMenu(context, show, book, thing, ground),
        child: Container(
          width: 74,
          padding: const EdgeInsets.fromLTRB(5, 4, 5, 4),
          decoration: BoxDecoration(
            color: a.from == RuleFrom.yourException ? Console.a.withValues(alpha: 0.12) : Console.raised,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: onStage ? Console.b : edge, width: onStage || a.from != RuleFrom.rule ? 1.5 : 1),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_groundWord(ground), style: Console.label(7.5, color: Console.ink), maxLines: 1, overflow: TextOverflow.clip),
            const SizedBox(height: 3),
            _RuleFace(rule: a.rule, mine: false, black: a.from == RuleFrom.black),
            const SizedBox(height: 3),
            Text(a.from == RuleFrom.black ? 'as drawn' : (a.never ? 'never' : (a.rule.ground ?? GroundMode.over).name),
                style: TextStyle(fontSize: 9, color: a.never ? Console.faint : Console.ink), maxLines: 1, overflow: TextOverflow.clip),
            Text(_fromWords(a.from),
                style: TextStyle(fontSize: 8, color: a.from == RuleFrom.rule || a.from == RuleFrom.black ? Console.faint : edge), maxLines: 1),
          ]),
        ),
      ),
    );
  }
}

/// A rule's face: the way's little picture, or a bar for never.
class _RuleFace extends StatelessWidget {
  const _RuleFace({required this.rule, required this.mine, this.black = false});
  final ComboRule rule;
  final bool mine, black;

  @override
  Widget build(BuildContext context) {
    final Widget face = rule.off
        ? Container(width: 44, height: 24, alignment: Alignment.center, color: Console.ground, child: Icon(Icons.block, size: 14, color: Console.faint))
        : _BlendSwatch(black ? GroundMode.over : (rule.ground ?? GroundMode.over), width: 44, height: 24);
    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(3), border: mine ? Border.all(color: Console.a, width: 1.5) : null),
      child: ClipRRect(borderRadius: BorderRadius.circular(3), child: face),
    );
  }
}

// ---------------------------------------------------------------- RULES
/// What goes on what: the twelve rules (a character on a background's), the
/// exceptions, and — folded — every pair at once.
class _RulesTab extends StatelessWidget {
  const _RulesTab({required this.show, required this.kit, required this.links});
  final ShowEngine show;
  final StageKit? kit;
  final _Links links;

  @override
  Widget build(BuildContext context) {
    final book = kit?.book;
    if (book == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: show,
      builder: (context, _) {
        final pool = show.pool;
        final rig = show.state.rig;
        final nowFigure = ShowPool.lookupFigure(rig.figure);
        final alone = rig.figure.kind == Figure.none;
        final nowAnswer = alone ? null : pool.answer(nowFigure, rig.ground.kind);
        final nowThing = alone
            ? null
            : (nowFigure.style != null ? _StyleThing(nowFigure.kind, nowFigure.style!) : (show.state.scene != null ? _SceneThing(show.state.scene!) : null));
        final pairsOpen = show.doc.panel['pairsOpen'] == true;
        final exceptions = <String, (ComboRule, bool)>{
          for (final e in shippedExceptions.entries) e.key: (e.value, false),
          for (final e in pool.combos.entries) e.key: (e.value, true),
        };
        final keys = exceptions.keys.toList()..sort();
        return ListView(
          children: [
            Text(
                'Every scene and style has a character, every background one too. A rule says how a character goes on a background\'s; '
                'an exception says otherwise for one thing on one background. The director keeps to them; your own taps on the rig do not. '
                'Hold any chip for its card.',
                style: TextStyle(fontSize: 11, color: Console.quiet, height: 1.35)),
            const SizedBox(height: 8),
            Row(children: [
              Text('NOW', style: Console.label(9, color: Console.a)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  alone
                      ? '${book[show.state.scene]?.name ?? '—'}: its own whole picture, no rule'
                      : '${_thingName(nowThing ?? _SceneThing(show.state.scene ?? ''), book)} on ${_groundWord(rig.ground.kind)} — ${_answerWords(nowAnswer!)}',
                  style: TextStyle(fontSize: 11, color: Console.ink),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (nowThing != null) Pad(label: 'ITS CARD', height: 22, colour: Console.quiet, onTap: () => links.card(nowThing)),
            ]),
            const SizedBox(height: 12),
            Text('THE RULES', style: Console.label(10, color: Console.ink)),
            const SizedBox(height: 6),
            Table(
              columnWidths: const {0: FlexColumnWidth(1.5), 1: FlexColumnWidth(), 2: FlexColumnWidth(), 3: FlexColumnWidth()},
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                TableRow(children: [
                  const SizedBox.shrink(),
                  for (final b in Backdrop.values)
                    Tooltip(
                      message: b.words,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 4, left: 3, right: 3),
                        child: Column(children: [
                          Text(b.title.toUpperCase(), style: Console.label(8.5, color: Console.ink)),
                          Text(_groundsOf(b, pool).join(' · '), style: TextStyle(fontSize: 9, color: Console.faint), textAlign: TextAlign.center, maxLines: 2),
                        ]),
                      ),
                    ),
                ]),
                for (final c in Character.values)
                  TableRow(children: [
                    Tooltip(
                      message: c.words,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(c.title, style: TextStyle(fontSize: 12, color: Console.ink, fontWeight: FontWeight.w600)),
                          Text(_membersOf(c, pool, book).join(' · '),
                              style: TextStyle(fontSize: 9, color: Console.faint, height: 1.25), maxLines: 3, overflow: TextOverflow.ellipsis),
                        ]),
                      ),
                    ),
                    for (final b in Backdrop.values)
                      _RuleCellOf(show: show, character: c, backdrop: b, now: nowAnswer != null && nowAnswer.character == c && nowAnswer.backdrop == b),
                  ]),
              ],
            ),
            const SizedBox(height: 4),
            Text('On black every scene is drawn as it is. Tap a rule to change it for everything of that character.',
                style: TextStyle(fontSize: 10, color: Console.faint)),
            const SizedBox(height: 14),
            Text('EXCEPTIONS · ${keys.length}', style: Console.label(10, color: Console.ink)),
            const SizedBox(height: 4),
            for (final k in keys) _ExceptionLine(show: show, book: book, links: links, pairKey: k, rule: exceptions[k]!.$1, mine: exceptions[k]!.$2),
            Text('Add one from a card\'s GOES WITH (hold any chip), or from every pair below.', style: TextStyle(fontSize: 10, color: Console.faint)),
            const SizedBox(height: 12),
            InkWell(
              onTap: () => show.setDoc(show.doc.copyWith(panel: {...show.doc.panel, 'pairsOpen': !pairsOpen})),
              child: Row(children: [
                Icon(pairsOpen ? Icons.expand_more : Icons.chevron_right, size: 16, color: Console.quiet),
                Text('EVERY PAIR', style: Console.label(10, color: Console.ink)),
                const SizedBox(width: 8),
                Expanded(
                    child: Text('each scene and style on each background, as the rules and the exceptions answer',
                        style: TextStyle(fontSize: 10, color: Console.faint))),
              ]),
            ),
            if (pairsOpen) ...[const SizedBox(height: 6), _EveryPair(show: show, book: book)],
            const SizedBox(height: 14),
            Row(children: [
              Text('DIRECTOR', style: Console.label(10, color: Console.ink)),
              const SizedBox(width: 10),
              Text('calm', style: Console.label(9)),
              Expanded(child: Slider(value: pool.bias, min: -1, max: 1, onChanged: (v) => show.setPool(pool.copyWith(bias: v)))),
              Text('busy', style: Console.label(9)),
            ]),
            Text('calm leans to the quieter scenes, busy to the louder', style: TextStyle(fontSize: 10, color: Console.faint)),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: Text('the beat before a drop goes black', style: TextStyle(fontSize: 12, color: Console.ink))),
              Switch(value: pool.darkBeat, onChanged: (v) => show.setPool(pool.copyWith(darkBeat: v))),
            ]),
          ],
        );
      },
    );
  }
}

/// One of the twelve rules: its picture and its words; yours in the accent; the one
/// answering the stage now ringed.
class _RuleCellOf extends StatelessWidget {
  const _RuleCellOf({required this.show, required this.character, required this.backdrop, required this.now});
  final ShowEngine show;
  final Character character;
  final Backdrop backdrop;
  final bool now;

  @override
  Widget build(BuildContext context) {
    final (r, mine) = show.pool.ruleOf(character, backdrop);
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Tooltip(
        message:
            '${character.title} on ${backdrop.title.toLowerCase()}: ${_wayWords(r)}${mine ? ' (yours)' : ' — ${shippedRuleWhy[ruleKey(character, backdrop)] ?? ''}'}',
        waitDuration: const Duration(milliseconds: 400),
        child: InkWell(
          borderRadius: BorderRadius.circular(5),
          onTap: () => _ruleMenu(context, show, character, backdrop),
          child: Container(
            padding: const EdgeInsets.fromLTRB(5, 5, 5, 4),
            decoration: BoxDecoration(
              color: mine ? Console.a.withValues(alpha: 0.12) : Console.raised,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: now ? Console.b : (mine ? Console.a : Console.line), width: now || mine ? 1.5 : 1),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _RuleFace(rule: r, mine: false),
              const SizedBox(height: 3),
              Text(r.off ? 'never' : (r.ground ?? GroundMode.over).name,
                  style: TextStyle(fontSize: 10, color: r.off ? Console.faint : (mine ? Console.a : Console.ink))),
              if (!r.off && r.figure == FigureMode.over) Text('figures on top', style: TextStyle(fontSize: 8, color: Console.quiet)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// An exception as a sentence: what, on what, how, why; whose; its way back.
class _ExceptionLine extends StatelessWidget {
  const _ExceptionLine({required this.show, required this.book, required this.links, required this.pairKey, required this.rule, required this.mine});
  final ShowEngine show;
  final SceneBook book;
  final _Links links;
  final String pairKey;
  final ComboRule rule;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final pool = show.pool;
    final silenced = !mine && (pool.combos[pairKey]?.follow ?? false);
    if (mine && rule.follow && shippedExceptions.containsKey(pairKey)) return const SizedBox.shrink();
    final why = shippedExceptionWhy[pairKey];
    final thing = _thingOfKey(pairKey);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Container(width: 3, height: 26, color: mine ? Console.a : Console.b),
        const SizedBox(width: 8),
        Expanded(
          child: InkWell(
            onTap: thing == null ? null : () => links.card(thing),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: '${_keyWords(pairKey)}: ', style: TextStyle(color: silenced ? Console.faint : Console.ink)),
                TextSpan(
                    text: rule.follow ? 'as the rule says' : _wayWords(rule),
                    style: TextStyle(color: silenced ? Console.faint : (mine ? Console.a : Console.b))),
                if (silenced) TextSpan(text: '  (off: the rule holds)', style: TextStyle(color: Console.faint)),
                if (!silenced && why != null) TextSpan(text: '  — $why', style: TextStyle(color: Console.faint)),
              ]),
              style: const TextStyle(fontSize: 11),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (mine)
          Pad(
              icon: Icons.close,
              width: 22,
              height: 22,
              colour: Console.quiet,
              tooltip: 'Forget this exception',
              onTap: () => show.setPool(pool.withCombo(pairKey, null)))
        else
          Pad(
            icon: silenced ? Icons.undo : Icons.do_not_disturb_on_outlined,
            width: 22,
            height: 22,
            colour: Console.quiet,
            tooltip: silenced ? 'Let this exception hold again' : 'Switch it off: the rule holds for this pair',
            onTap: () => show.setPool(pool.withCombo(pairKey, silenced ? null : ComboRule.asTheRule)),
          ),
      ]),
    );
  }
}

/// The thing a pair key is about.
_Thing? _thingOfKey(String key) {
  final fig = key.split('|').first.split('.');
  if (fig.length < 2) return null;
  final kind = Figure.values.where((f) => f.name == fig[1]).firstOrNull;
  if (kind == null) return null;
  if (fig.length > 3 && fig[2] == 'style') return _StyleThing(kind, fig[3]);
  return switch (kind) {
    Figure.dancers => const _SceneThing('dance-art'),
    Figure.birds => const _SceneThing('flock'),
    Figure.words => const _SceneThing('lyrics'),
    _ => null,
  };
}

/// A pair key in words: `Dancer · mono on MilkDrop`.
String _keyWords(String key) {
  final parts = key.split('|');
  final fig = parts[0].split('.');
  final kind = Figure.values.where((f) => f.name == (fig.length > 1 ? fig[1] : '')).firstOrNull;
  final kindWord = kind == null ? (fig.length > 1 ? fig[1] : '?') : _figureWord(kind, null).replaceFirst('Dancers', 'Dancer');
  final named = switch (kind) {
    Figure.dancers => 'Dancer',
    Figure.birds => 'Murmuration',
    Figure.words => 'Lyrics',
    Figure.meme => 'Siebenschläfer',
    Figure.field => 'Drift',
    _ => kindWord,
  };
  final sub = fig.length > 3 ? fig[3] : null;
  final gName = parts.length > 1 ? parts[1].split('.').last : '?';
  final g = Ground.values.where((x) => x.name == gName).firstOrNull;
  return '$named${sub != null ? ' · $sub' : ''} on ${g == null ? gName : _groundWord(g)}';
}

/// Every pair: a row per figure (and, open, per style), a column per background, each
/// cell the answer, its edge whose it is.
class _EveryPair extends StatelessWidget {
  const _EveryPair({required this.show, required this.book});
  final ShowEngine show;
  final SceneBook book;

  Set<String> _open() {
    final v = show.doc.panel['rulesOpen'];
    return v is List ? {for (final x in v) '$x'} : {'dancers'};
  }

  void _toggle(String kind) {
    final open = _open();
    open.contains(kind) ? open.remove(kind) : open.add(kind);
    show.setDoc(show.doc.copyWith(panel: {...show.doc.panel, 'rulesOpen': open.toList()}));
  }

  @override
  Widget build(BuildContext context) {
    final open = _open();
    final rows = <(String, _Thing, int)>[];
    final seen = <Figure>{};
    for (final s in book.scenes.values.toList()..sort((a, b) => a.name.compareTo(b.name))) {
      final f = s.look.rig.figure;
      if (f.kind == Figure.none || !seen.add(f.kind)) continue;
      final styles = _stylesOf(f.kind);
      rows.add((f.kind == Figure.room ? 'Echo · Fold' : s.name, _SceneThing(s.id), styles.length));
      if (styles.isNotEmpty && open.contains(f.kind.name)) {
        for (final st in styles) {
          rows.add((st, _StyleThing(f.kind, st), 0));
        }
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Table(
        defaultColumnWidth: const FixedColumnWidth(50),
        columnWidths: const {0: FlexColumnWidth()},
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(children: [
            const SizedBox.shrink(),
            for (final g in _ruleGrounds)
              Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(_groundWord(g), textAlign: TextAlign.center, style: Console.label(7.5, color: Console.ink))),
          ]),
          for (final (name, thing, styles) in rows)
            TableRow(children: [
              styles > 0
                  ? InkWell(
                      onTap: () => _toggle((_figureOf(thing, book)?.kind ?? Figure.none).name),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(children: [
                          Icon(open.contains((_figureOf(thing, book)?.kind ?? Figure.none).name) ? Icons.expand_more : Icons.chevron_right,
                              size: 14, color: Console.quiet),
                          Flexible(
                              child: Text('$name · $styles styles',
                                  style: TextStyle(fontSize: 11, color: Console.ink, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                        ]),
                      ),
                    )
                  : Padding(
                      padding: EdgeInsets.only(left: thing is _StyleThing ? 18 : 0, top: 3, bottom: 3),
                      child:
                          Text(name, style: TextStyle(fontSize: thing is _StyleThing ? 10.5 : 11, color: thing is _StyleThing ? Console.quiet : Console.ink)),
                    ),
              for (final g in _ruleGrounds) _PairCell(show: show, book: book, thing: thing, ground: g),
            ]),
        ],
      ),
      const SizedBox(height: 4),
      Wrap(spacing: 10, children: [
        _Legend(colour: Console.raised, border: Console.line, word: 'the rule'),
        _Legend(colour: Console.raised, border: Console.b, word: 'an exception'),
        _Legend(colour: Console.a.withValues(alpha: 0.15), border: Console.a, word: 'yours'),
        _Legend(colour: Console.ground, border: Console.line, word: 'never', faint: true),
      ]),
    ]);
  }
}

class _PairCell extends StatelessWidget {
  const _PairCell({required this.show, required this.book, required this.thing, required this.ground});
  final ShowEngine show;
  final SceneBook book;
  final _Thing thing;
  final Ground ground;

  @override
  Widget build(BuildContext context) {
    final a = show.pool.answer(_figureOf(thing, book)!, ground);
    final edge = _fromColour(a.from);
    final mine = a.from == RuleFrom.yourException;
    final plain = a.from == RuleFrom.black || (!a.never && (a.rule.ground ?? GroundMode.over) == GroundMode.over);
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Tooltip(
        message: '${_thingName(thing, book)} on ${_groundWord(ground)}: ${_answerWords(a)}',
        waitDuration: const Duration(milliseconds: 500),
        child: InkWell(
          onTap: a.from == RuleFrom.black ? null : () => _pairMenu(context, show, book, thing, ground),
          child: Container(
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: a.never ? Console.ground : (mine ? Console.a.withValues(alpha: 0.15) : Console.raised),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: edge, width: a.from == RuleFrom.exception || mine ? 1.5 : 1),
            ),
            child: a.never
                ? Icon(Icons.block, size: 12, color: Console.faint)
                : plain
                    ? Icon(Icons.check, size: 12, color: mine ? Console.a : Console.quiet)
                    : Text(a.rule.ground!.name, style: TextStyle(fontSize: 9.5, color: mine ? Console.a : Console.ink)),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- EVERYTHING
/// Every scene, style and background: what each is, how often it comes on; a tap
/// for its card.
class _EverythingTab extends StatelessWidget {
  const _EverythingTab({required this.show, required this.kit, required this.links});
  final ShowEngine show;
  final StageKit? kit;
  final _Links links;

  @override
  Widget build(BuildContext context) {
    final book = kit?.book;
    if (book == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: show,
      builder: (context, _) {
        final pool = show.pool;
        final scenes = book.scenes.values.toList()..sort((a, b) => a.name.compareTo(b.name));
        final byFamily = <_Family, List<Scene>>{};
        for (final s in scenes) {
          byFamily.putIfAbsent(_familyOf(s), () => []).add(s);
        }
        Widget head(String w, String tip) => Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Row(children: [
                Text(w, style: Console.label(9, color: Console.ink)),
                const SizedBox(width: 8),
                Expanded(child: Text(tip, style: TextStyle(fontSize: 10, color: Console.faint), overflow: TextOverflow.ellipsis)),
              ]),
            );
        return ListView(children: [
          Text('Every scene, style and background. Tap one for its card: what it is, how often it comes on, what it goes with.',
              style: TextStyle(fontSize: 11, color: Console.quiet)),
          head('SCENES', 'how often the director puts each on'),
          for (final f in _Family.values)
            for (final s in byFamily[f] ?? const <Scene>[])
              _ThingRow(show: show, book: book, links: links, thing: _SceneThing(s.id), on: show.state.scene == s.id),
          head('DANCER STYLES', 'how often the dancers\' clock picks each'),
          for (final st in _stylesOf(Figure.dancers))
            if (st != 'contour' || pool.styleOn(Figure.dancers, st))
              _ThingRow(show: show, book: book, links: links, thing: _StyleThing(Figure.dancers, st), on: _styleOnStage(show, Figure.dancers, st)),
          head('FLOCK LOOKS', 'how often the flock\'s clock picks each'),
          for (final st in _stylesOf(Figure.birds))
            _ThingRow(show: show, book: book, links: links, thing: _StyleThing(Figure.birds, st), on: _styleOnStage(show, Figure.birds, st)),
          head('BACKGROUNDS', 'how often the director puts each under a scene'),
          for (final g in _ruleGrounds) _ThingRow(show: show, book: book, links: links, thing: _GroundThing(g), on: show.state.rig.ground.kind == g),
        ]);
      },
    );
  }
}

bool _styleOnStage(ShowEngine show, Figure kind, String style) {
  final f = ShowPool.lookupFigure(show.state.rig.figure);
  return f.kind == kind && f.style == style;
}

/// A row of EVERYTHING: picture, name, character, how often; a tap for the card.
class _ThingRow extends StatelessWidget {
  const _ThingRow({required this.show, required this.book, required this.links, required this.thing, required this.on});
  final ShowEngine show;
  final SceneBook book;
  final _Links links;
  final _Thing thing;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final pool = show.pool;
    final figure = _figureOf(thing, book);
    final whole = thing is _SceneThing && figure?.kind == Figure.none;
    final String character;
    if (thing is _GroundThing) {
      character = pool.backdropOf((thing as _GroundThing).ground)?.title ?? 'nothing';
    } else if (whole) {
      character = 'its own whole picture';
    } else {
      character = pool.characterOf(figure ?? const RigFigure()).title;
    }
    final key = _oftenKey(thing);
    final often = key == null ? null : pool.oftenOf(key);
    return InkWell(
      onTap: () => links.card(thing),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          _thingPicture(thing, w: 48, h: 27),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (on) Icon(Icons.play_arrow, size: 13, color: Console.a),
                Flexible(
                  child: Text(thing is _StyleThing ? (thing as _StyleThing).style : _thingName(thing, book),
                      style: TextStyle(fontSize: 12.5, color: often == Often.never ? Console.faint : Console.ink), overflow: TextOverflow.ellipsis),
                ),
              ]),
              Text(character.toLowerCase(), style: TextStyle(fontSize: 9.5, color: Console.quiet)),
            ]),
          ),
          if (often != null)
            for (final o in Often.values)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: IntrinsicWidth(
                    child: Pad(
                  label: o.word,
                  height: 20,
                  lit: o == often,
                  colour: o == Often.normal ? Console.quiet : Console.a,
                  tooltip: '${o.word}: ${o.words}',
                  onTap: () => show.setPool(pool.withOften(key!, o)),
                )),
              ),
        ]),
      ),
    );
  }
}
