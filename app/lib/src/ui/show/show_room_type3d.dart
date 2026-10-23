// The TEXT tab: the 3D type's words and how they are shown (state/show/show_type3d.dart
// TypeSpec, kept in the pool): the lines, when the next comes, the face, the motions
// and the looks a phrase picks from, the colours, and the knobs — size, depth, bevel,
// speed, the beat's push, the glow. SHOW IT puts the 3D text on the stage, held.
part of 'show_room.dart';

class _Type3dTab extends StatefulWidget {
  const _Type3dTab({required this.show});
  final ShowEngine show;

  @override
  State<_Type3dTab> createState() => _Type3dTabState();
}

class _Type3dTabState extends State<_Type3dTab> {
  ShowEngine get show => widget.show;
  late final _lines = TextEditingController(text: show.pool.type3d.lines.join('\n'));
  Timer? _typing;

  @override
  void dispose() {
    _typing?.cancel();
    _lines.dispose();
    super.dispose();
  }

  void _put(TypeSpec Function(TypeSpec) f) => show.setPool(show.pool.copyWith(type3d: f(show.pool.type3d)));

  /// The lines as typed, a moment after the typing stops (each change sets the type
  /// afresh on the stage).
  void _typed(String v) {
    _typing?.cancel();
    _typing = Timer(const Duration(milliseconds: 500), () => _put((s) => s.copyWith(lines: v.split('\n'))));
  }

  static String _motionTip(TypeMotion m) => switch (m) {
        TypeMotion.spin => 'Turning round, a turn every two bars',
        TypeMotion.tumble => 'Turning about every way at once, slowly',
        TypeMotion.swing => 'Rocking side to side on the beat',
        TypeMotion.flip => 'A whole turn over on each bar\'s first beat',
        TypeMotion.wave => 'A wave running through the letters',
        TypeMotion.twist => 'Wrung about its length, back and forth over the bar',
        TypeMotion.orbit => 'Circling the middle',
        TypeMotion.zoom => 'Flying in from far off over a phrase',
        TypeMotion.bounce => 'Hopping on every beat',
        TypeMotion.drift => 'Close up: the letters fill the view and glide past, cropped',
        TypeMotion.still => 'Facing you; only the beat\'s push',
      };

  static String _lookTip(TypeLook l) => switch (l) {
        TypeLook.chrome => 'Polished metal mirroring a purple studio',
        TypeLook.neon => 'Dark letters, their edges tubes of light',
        TypeLook.solid => 'Painted faces, deeper sides, a highlight',
        TypeLook.outline => 'The edges alone, in light; the background through the faces',
        TypeLook.hologram => 'A see-through light, scanned',
        TypeLook.iridescent => 'A foil: a thin film\'s colours turning with the angle',
        TypeLook.glass => 'Clear glass bending what is behind it (MilkDrop through the letters)',
        TypeLook.aurora => 'A soft gradient of the three colours flowing through it',
        TypeLook.pop => 'Print: flat colours, a black outline, halftone dots in the shade',
        TypeLook.stripes => 'Op art: bands sweeping through it on the beat',
        TypeLook.mercury => 'Liquid metal, its surface never still',
      };

  static String _bendTip(TypeDeform d) => switch (d) {
        TypeDeform.inflate => 'Puffed up on the kick, rounder',
        TypeDeform.ripple => 'Rings running out from the middle on the beat, deeper with the bass',
        TypeDeform.melt => 'Dripping down over the phrase (the quieter, the more), re-formed on the next',
        TypeDeform.slice => 'Torn sideways in bands on the snare',
        TypeDeform.shatter => 'Flown apart on the drop, cracking through a build; always on when lit',
        TypeDeform.wobble => 'A liquid wobble with the hats',
        TypeDeform.squash => 'Flattened and widened on the kick',
        TypeDeform.arc => 'Curved along its length, rocking over the bar',
        TypeDeform.stack => 'Echoes stacked behind it, spreading on the kick',
        TypeDeform.repeat => 'Rows of it above and below, scrolling: the view full of it',
      };

  static String _turnTip(TypeTurn t) => switch (t) {
        TypeTurn.morph => 'The letters flow into the next ones',
        TypeTurn.flip => 'Turned over edge-on, the next on the other side',
        TypeTurn.glitch => 'Cut over in torn bands',
      };

  static (Color, Color) _swatch(TypeColour c) => switch (c) {
        TypeColour.record => (const Color(0xff7a6a9a), const Color(0xff3a2d55)),
        TypeColour.purple => (const Color(0xffe9b8ff), const Color(0xff5b1fa8)),
        TypeColour.sunset => (const Color(0xffffd27a), const Color(0xffe0405a)),
        TypeColour.ice => (const Color(0xffcff6ff), const Color(0xff3a7bd5)),
        TypeColour.gold => (const Color(0xffffe6a0), const Color(0xffa8741a)),
        TypeColour.mono => (const Color(0xffffffff), const Color(0xff8a8a8a)),
      };

  Widget _row(String word, String hint, Widget child) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_Head(word, hint: hint), child]),
      );

  Widget _chip(String label, bool lit, VoidCallback onTap, {String? tip, TextStyle? face}) => Padding(
        padding: const EdgeInsets.only(right: 4, bottom: 4),
        child: Tooltip(
          message: tip ?? label,
          waitDuration: const Duration(milliseconds: 500),
          child: InkWell(
            onTap: () {
              feel(Feel.pick);
              onTap();
            },
            borderRadius: BorderRadius.circular(6),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: lit ? Console.a.withValues(alpha: 0.18) : Console.raised,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: lit ? Console.a : Console.line, width: lit ? 1.5 : 1),
              ),
              child: Text(label, style: face ?? Console.label(9.5, color: lit ? Console.a : Console.ink)),
            ),
          ),
        ),
      );

  /// A set of a row's things toggled, never empty.
  static Set<T> _flip<T>(Set<T> s, T x) {
    final next = {...s};
    if (!next.remove(x)) next.add(x);
    return next.isEmpty ? s : next;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: show,
        builder: (context, _) {
          final spec = show.pool.type3d;
          final on = show.state.scene == 'type3d';
          Widget knob(String label, String tip, double v, TypeSpec Function(double) set) => Padding(
                padding: const EdgeInsets.only(right: 14),
                child: Knob(
                  value: v,
                  min: 0,
                  max: TypeSpec.knobRange.$2,
                  rest: 1,
                  bipolar: false,
                  size: 34,
                  label: label,
                  tooltip: '$tip: × ${v.toStringAsFixed(2)} (double-click: as drawn)',
                  onChanged: (x) => _put((_) => set(x)),
                ),
              );
          return ListView(children: [
            Row(children: [
              Expanded(
                child: Text('Your words as solid 3D letters, turned and bent by the music. A phrase picks one of the motions, one of the looks and two of the bends lit below.',
                    style: TextStyle(fontSize: 11, color: Console.quiet)),
              ),
              IntrinsicWidth(
                child: Pad(
                  icon: Icons.play_arrow,
                  label: on ? 'ON THE STAGE' : 'SHOW IT',
                  height: 26,
                  lit: on,
                  colour: Console.a,
                  tooltip: 'The 3D text on the stage now, held until you let go (HOLD)',
                  onTap: () => show.play(Combo(ground: show.combo?.ground == ownGround ? 'black' : (show.combo?.ground ?? 'black'), scene: 'type3d', style: 'raw')),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            _row(
              'LINES',
              'one a line, shown in turn · {title} and {artist} are the record\'s',
              TextField(
                controller: _lines,
                minLines: 2,
                maxLines: 5,
                style: TextStyle(fontSize: 13, color: Console.ink),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: Console.raised,
                  hintText: 'WETOWL\n{artist}',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: Console.line)),
                ),
                onChanged: _typed,
              ),
            ),
            _row(
              'NEXT LINE',
              'when the next line comes',
              Wrap(children: [
                for (final c in TypeChange.values)
                  _chip(
                    switch (c) {
                      TypeChange.beat => 'EVERY BEAT',
                      TypeChange.bar => 'EVERY BAR',
                      TypeChange.twoBars => 'EVERY 2 BARS',
                      TypeChange.phrase => 'EVERY PHRASE',
                      TypeChange.eightBars => 'EVERY 8 BARS',
                      TypeChange.never => 'NEVER',
                    },
                    spec.change == c,
                    () => _put((s) => s.copyWith(change: c)),
                  ),
              ]),
            ),
            _row(
              'TURN',
              'how one line becomes the next',
              Wrap(children: [
                for (final t in TypeTurn.values) _chip(t.name.toUpperCase(), spec.turn == t, () => _put((s) => s.copyWith(turn: t)), tip: _turnTip(t)),
              ]),
            ),
            _row(
              'FONT',
              'the face the letters are cut from',
              Wrap(children: [
                for (final f in TypeFont.values)
                  _chip(f.label, spec.font == f, () => _put((s) => s.copyWith(font: f)),
                      face: TextStyle(fontFamily: f.family, fontSize: f == TypeFont.pixel ? 9 : 14, color: spec.font == f ? Console.a : Console.ink, height: 1.1)),
              ]),
            ),
            _row(
              'MOTION',
              'any of these, one a phrase (tap to add or take away)',
              Wrap(children: [
                for (final m in TypeMotion.values)
                  _chip(m.name.toUpperCase(), spec.motions.contains(m), () => _put((s) => s.copyWith(motions: _flip(s.motions, m))), tip: _motionTip(m)),
              ]),
            ),
            _row(
              'LOOK',
              'what the letters are made of, one a phrase',
              Wrap(children: [
                for (final l in TypeLook.values)
                  _chip(l.name.toUpperCase(), spec.looks.contains(l), () => _put((s) => s.copyWith(looks: _flip(s.looks, l))), tip: _lookTip(l)),
              ]),
            ),
            _row(
              'BEND',
              'how the music bends it, two a phrase, each to its own part of the music (none: as cut)',
              Wrap(children: [
                for (final d in TypeDeform.values)
                  _chip(d.name.toUpperCase(), spec.deforms.contains(d), () {
                    final next = {...spec.deforms};
                    if (!next.remove(d)) next.add(d);
                    _put((s) => s.copyWith(deforms: next));
                  }, tip: _bendTip(d)),
              ]),
            ),
            _row(
              'COLOUR',
              'the record\'s own, or a set of your choosing',
              Wrap(children: [
                for (final c in TypeColour.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 4, bottom: 4),
                    child: InkWell(
                      onTap: () => _put((s) => s.copyWith(colour: c)),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(5, 4, 8, 4),
                        decoration: BoxDecoration(
                          color: spec.colour == c ? Console.a.withValues(alpha: 0.18) : Console.raised,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: spec.colour == c ? Console.a : Console.line, width: spec.colour == c ? 1.5 : 1),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(3),
                              gradient: LinearGradient(colors: [_swatch(c).$1, _swatch(c).$2], begin: Alignment.topCenter, end: Alignment.bottomCenter),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(c.name.toUpperCase(), style: Console.label(9.5, color: spec.colour == c ? Console.a : Console.ink)),
                        ]),
                      ),
                    ),
                  ),
              ]),
            ),
            _row(
              'KNOBS',
              '1 is as drawn',
              _Line(children: [
                knob('SIZE', 'How big the letters are', spec.size, (x) => spec.copyWith(size: x)),
                knob('DEPTH', 'How deep the letters are cut', spec.depth, (x) => spec.copyWith(depth: x)),
                knob('BEVEL', 'How rounded their edges are', spec.bevel, (x) => spec.copyWith(bevel: x)),
                knob('SPEED', 'How fast they move', spec.speed, (x) => spec.copyWith(speed: x)),
                knob('BEAT', 'How hard the beat pushes them', spec.beat, (x) => spec.copyWith(beat: x)),
                knob('GLOW', 'How much they glow', spec.glow, (x) => spec.copyWith(glow: x)),
                knob('BEND', 'How far the music bends them', spec.bend, (x) => spec.copyWith(bend: x)),
                _Word(
                  label: 'RESET',
                  lit: false,
                  tooltip: 'Every knob back as drawn',
                  onTap: () => _put((s) => s.copyWith(size: 1, depth: 1, bevel: 1, speed: 1, beat: 1, glow: 1, bend: 1)),
                ),
              ]),
            ),
          ]);
        },
      );
}
