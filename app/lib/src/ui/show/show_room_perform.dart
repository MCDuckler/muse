// PERFORM: the picture and what is on, in words and in its share of the night; the
// judging of what is on in a tap — NEVER THIS (and WIDER: any mask and blend, then
// the style in this scene), LESS, MORE, KEEP; everything the hands hold, each let go
// of on its own or all at once; NEXT · MOSH · HOLD; and the pads to play the light
// with.
part of 'show_room.dart';

class _Perform extends StatelessWidget {
  const _Perform({
    required this.booth,
    required this.kit,
    required this.trouble,
    required this.info,
    required this.previewHeight,
    required this.onPreviewDrag,
    required this.onPreviewDone,
    required this.onScene,
  });
  final Booth booth;
  final StageKit? kit;
  final String? trouble;
  final ValueNotifier<StageInfo> info;
  final double previewHeight;
  final ValueChanged<double> onPreviewDrag;
  final VoidCallback onPreviewDone;
  final void Function(String?) onScene;

  @override
  Widget build(BuildContext context) {
    final show = booth.show;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Preview(booth: booth, kit: kit, trouble: trouble, info: info, maxHeight: previewHeight, onScene: onScene),
      _Seam(vertical: true, tip: 'Drag: the picture taller or shorter', onDrag: onPreviewDrag, onDone: onPreviewDone),
      Expanded(
        child: BoothPanel(
          child: Plate(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _Judge(show: show, kit: kit),
                const SizedBox(height: 8),
                _Holds(show: show, kit: kit),
                const SizedBox(height: 10),
                _Controls(show: show),
                const SizedBox(height: 8),
                _Pads(show: show),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }
}

// ------------------------------------------------------------------ the picture
class _Preview extends StatelessWidget {
  const _Preview({required this.booth, required this.kit, required this.trouble, required this.info, required this.maxHeight, required this.onScene});
  final Booth booth;
  final double maxHeight;
  final StageKit? kit;
  final String? trouble;
  final ValueNotifier<StageInfo> info;
  final void Function(String?) onScene;

  @override
  Widget build(BuildContext context) {
    final show = booth.show;
    return BoothPanel(
      child: Plate(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: ColoredBox(
                      color: Colors.black,
                      child: trouble != null
                          ? Center(child: Text('The stage could not load.\n$trouble', style: TextStyle(color: Console.quiet)))
                          : kit == null
                              ? const SizedBox.shrink()
                              : GrabbableStage(child: StagePreview(feed: show, book: kit!.book, programs: kit!.programs, scale: 1.0, rank: 1, info: info)),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            ListenableBuilder(
              listenable: show,
              builder: (context, _) => ValueListenableBuilder<StageInfo>(
                valueListenable: info,
                builder: (context, i, _) {
                  final m = show.state.master;
                  final c = show.combo;
                  final book = kit?.book;
                  final share = c == null || show.kinds.isEmpty ? null : _sharesOf(show).ofNight(c);
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Text('NOW', style: Console.label(9, color: Console.a)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: InkWell(
                          onTap: c == null ? null : () => onScene(c.scene),
                          child: Text(
                            c == null ? (show.state.scene == null ? '—' : book?[show.state.scene]?.name ?? show.state.scene!) : _comboWords(c, book),
                            style: TextStyle(color: Console.ink, fontSize: 12.5, fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      Pad(
                          icon: Icons.fullscreen,
                          width: 26,
                          height: 24,
                          colour: Console.quiet,
                          tooltip: 'The stage over this window (⇧V)',
                          onTap: kit == null ? null : () => openStagePage(context, booth)),
                      const SizedBox(width: 4),
                      Pad(
                        icon: Icons.open_in_new,
                        width: 26,
                        height: 24,
                        colour: Console.quiet,
                        tooltip: 'The stage in a window of its own (⌥V)',
                        onTap: canPopOutStage ? () => unawaited(popOutStage(context.read<AppState?>()?.boardLink)) : null,
                      ),
                    ]),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (share != null) 'about ${shareWord(share)} of the night',
                        if (m.section != null) m.section!,
                        if (m.dropBeatsAway != null && m.dropBeatsAway! > 0) 'drop in ${m.dropBeatsAway!.ceil()}',
                        '${i.word}${i.parked ? ' parked' : ''}${i.fps > 0 ? ' ${i.fps.round()} fps' : ''}',
                      ].join(' · '),
                      style: TextStyle(color: Console.quiet, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ]);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ the judging
/// NEVER THIS · LESS · MORE · KEEP, on the combination on: written into its scene's
/// cells (show_plan.dart), where its page's grid shows them.
class _Judge extends StatelessWidget {
  const _Judge({required this.show, required this.kit});
  final ShowEngine show;
  final StageKit? kit;

  /// How wide a NEVER reaches: this look; this style on this background, any mask and
  /// blend; this style anywhere in the scene.
  static const _scopes = 3;

  void _never(BuildContext context, Combo c, int scope, ShowPlan before) {
    final messenger = ScaffoldMessenger.of(context);
    final world = c.world;
    final book = kit?.book;
    final scene = book?[c.scene]?.name ?? c.scene;
    final s = world ? 2 : scope;
    final (plan, words) = switch (s) {
      0 => (before.withCell(c.scene, cellOf(c), 0), 'Never: ${_comboWords(c, book)}'),
      1 => (before.withCell(c.scene, cellKey(style: c.style, ground: c.ground), 0), 'Never: $scene · ${c.style} on ${_groundName(c.ground)}, any mask and blend'),
      _ => (before.withIn(c.scene, PlanAxis.style, c.style, muted: true), 'Never: $scene in ${c.style == 'raw' ? 'its own style' : c.style}, on anything'),
    };
    show.setPlan(plan);
    feel(Feel.commit);
    messenger.say(snack(
      Row(children: [
        Expanded(child: Text(words, maxLines: 2, overflow: TextOverflow.ellipsis)),
        if (s < _scopes - 1)
          TextButton(
            onPressed: () {
              messenger.hideCurrentSnackBar();
              _never(context, c, s + 1, before);
            },
            child: const Text('WIDER'),
          ),
        TextButton(
          onPressed: () {
            messenger.hideCurrentSnackBar();
            show.setPlan(before);
          },
          child: const Text('UNDO'),
        ),
      ]),
      duration: const Duration(seconds: 5),
    ));
  }

  void _scale(BuildContext context, Combo c, double k) {
    final before = show.pool.plan;
    final key = cellOf(c);
    final next = before.scaleCell(c.scene, key, k);
    show.setPlan(next);
    feel(Feel.pick);
    final now = next.of(c.scene).cells[key] ?? 1;
    ScaffoldMessenger.of(context).say(snack(
      Text('${k < 1 ? 'Less' : 'More'}: ${_comboWords(c, kit?.book)} — ${levelWord(now)} its levels'),
      action: SnackBarAction(label: 'UNDO', onPressed: () => show.setPlan(before)),
    ));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: show,
        builder: (context, _) {
          final c = show.combo;
          final on = c != null;
          final cell = c == null ? null : show.pool.plan.of(c.scene).cells[cellOf(c)];
          return Row(children: [
            _Big(
              icon: Icons.block,
              label: 'NEVER THIS',
              tip: 'This look never again (the director moves on): the WIDER in the message takes in every mask and blend, then the style in this scene',
              onTap: !on ? null : () => _never(context, c, 0, show.pool.plan),
            ),
            _Big(
              icon: Icons.remove,
              label: 'LESS',
              tip: 'This look half as often${cell != null ? ' (now ${levelWord(cell)})' : ''}',
              onTap: !on || c.world ? null : () => _scale(context, c, 0.5),
            ),
            _Big(
              icon: Icons.add,
              label: 'MORE',
              tip: 'This look twice as often${cell != null ? ' (now ${levelWord(cell)})' : ''}',
              onTap: !on || c.world ? null : () => _scale(context, c, 2),
            ),
            _Big(
              icon: Icons.star_border,
              label: 'KEEP',
              tip: 'Keep what is on the stage as a favourite, as it is — MilkDrop preset, camera and all (P on the stage page)',
              onTap: !on ? null : () => unawaited(_keepFave(context, show, kit)),
            ),
          ]);
        },
      );
}

// ------------------------------------------------------------------ the holds
/// Everything the hands hold, each with its ×, and LET GO ALL.
class _Holds extends StatelessWidget {
  const _Holds({required this.show, required this.kit});
  final ShowEngine show;
  final StageKit? kit;

  String _words(ShowHold h) {
    final book = kit?.book;
    switch (h) {
      case ShowHold.look:
        final f = show.faveOn;
        if (f != null) return 'the favourite ${_faveTitle(f, book)}';
        if (show.milkOnly) return 'MilkDrop alone';
        final c = show.combo;
        return c == null ? 'the scene' : _comboWords(c, book);
      case ShowHold.ground:
        return '${_groundName(show.heldGround ?? '')} under everything';
      case ShowHold.effect:
        final f = show.heldFx ?? Fx.none;
        return f == Fx.none ? 'no effect, whatever comes' : '${_fxName(f).toLowerCase()} over everything';
      case ShowHold.preset:
        final d = MilkFeed.shared.director;
        return 'MilkDrop\'s preset${d.locked ? ', for good' : ''}';
      case ShowHold.pending:
        final what = show.pendingFave != null
            ? _faveTitle(show.pendingFave!, book)
            : show.pendingCombo != null
                ? _comboWords(show.pendingCombo!, book)
                : (book?[show.pendingLook]?.name ?? show.pendingLook ?? '');
        return '$what, on the next ${show.pendingAt?.name ?? 'bar'}';
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([show, MilkFeed.shared.director]),
        builder: (context, _) {
          final holds = show.holds;
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 46,
              child: Padding(padding: const EdgeInsets.only(top: 6), child: Text('HELD', style: Console.label(9, color: holds.isEmpty ? Console.faint : Console.a))),
            ),
            Expanded(
              child: holds.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text('nothing — the director has it all', style: TextStyle(fontSize: 11.5, color: Console.faint)),
                    )
                  : Wrap(spacing: 4, runSpacing: 4, children: [
                      for (final h in holds)
                        _HoldChip(
                          words: _words(h),
                          pending: h == ShowHold.pending,
                          onLetGo: () {
                            feel(Feel.pick);
                            show.letGo(h);
                          },
                        ),
                      if (holds.length > 1)
                        IntrinsicWidth(
                          child: Pad(
                            label: 'LET GO ALL',
                            height: 26,
                            colour: Console.a,
                            tooltip: 'Every hold let go: the director has it all again',
                            onTap: show.letGoAll,
                          ),
                        ),
                    ]),
            ),
          ]);
        },
      );
}

class _HoldChip extends StatelessWidget {
  const _HoldChip({required this.words, required this.onLetGo, this.pending = false});
  final String words;
  final bool pending;
  final VoidCallback onLetGo;

  @override
  Widget build(BuildContext context) => Container(
        height: 26,
        padding: const EdgeInsets.only(left: 9),
        decoration: BoxDecoration(
          color: Console.a.withValues(alpha: pending ? 0.06 : 0.14),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: pending ? Console.quiet : Console.a),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (pending) Padding(padding: const EdgeInsets.only(right: 5), child: Icon(Icons.schedule, size: 13, color: Console.quiet)),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Text(words, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: Console.ink)),
          ),
          Tooltip(
            message: pending ? 'Do not put it on' : 'Let go',
            child: InkResponse(
              onTap: onLetGo,
              radius: 14,
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.close, size: 14, color: Console.quiet)),
            ),
          ),
        ]),
      );
}

// ------------------------------------------------------------------ the buttons
/// NEXT, MOSH, HOLD.
class _Controls extends StatelessWidget {
  const _Controls({required this.show});
  final ShowEngine show;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: show,
        builder: (context, _) {
          final held = show.sceneHeld;
          return Row(children: [
            _Big(
                icon: Icons.skip_next,
                label: 'NEXT',
                tip: 'Another scene now (MilkDrop alone: another preset) — in a look\'s first bars, it comes a little less from then on',
                onTap: show.nextScene),
            _Big(
              icon: Icons.blur_linear,
              label: 'MOSH',
              tip: 'Another scene now, datamoshed into: the picture on dragged by the new one\'s motion until it breaks through (M on the stage page)',
              onTap: show.moshNext,
            ),
            _Big(
              icon: held ? Icons.lock : Icons.lock_open,
              label: held ? 'HELD' : 'HOLD',
              lit: held,
              tip: held ? 'Let the show change again' : 'Keep what is on — scene, style, background, mask, blend — until you let go (L on the stage page)',
              onTap: () => show.holdScene(!held),
            ),
          ]);
        },
      );
}

/// A big button: an icon and a word.
class _Big extends StatelessWidget {
  const _Big({required this.icon, required this.label, required this.tip, required this.onTap, this.lit = false});
  final IconData icon;
  final String label, tip;
  final bool lit;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final on = onTap != null;
    final fg = !on ? Console.faint : (lit ? Console.a : Console.ink);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Tooltip(
          message: tip,
          waitDuration: const Duration(milliseconds: 500),
          child: Material(
            color: lit ? Console.a.withValues(alpha: 0.16) : Console.raised,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: lit ? Console.a : Console.line)),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: !on
                  ? null
                  : () {
                      feel(Feel.commit);
                      onTap!();
                    },
              child: SizedBox(
                height: 44,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Padding(padding: const EdgeInsets.only(right: 6), child: Icon(icon, size: 18, color: fg)),
                  Flexible(child: Text(label, style: Console.label(9.5, color: fg), maxLines: 1, overflow: TextOverflow.ellipsis)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The pads to play the light with: hit, black, strobe (held), freeze, the level and
/// the hue; MilkDrop under everything; when what you put on lands.
class _Pads extends StatelessWidget {
  const _Pads({required this.show});
  final ShowEngine show;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: show,
        builder: (context, _) {
          final m = show.macros;
          final milk = show.heldGround == 'milk';
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _Flow(children: [
              Pad(label: 'HIT', height: 30, colour: Console.ink, tooltip: 'A flash on the stage (H on the stage page)', onTap: show.hit),
              const SizedBox(width: 4),
              Pad(
                label: 'BLACK',
                height: 30,
                lit: m.blackout,
                colour: Console.ink,
                tooltip: 'Blackout (B on the stage page)',
                onTap: () => show.setMacros(show.macros.copyWith(blackout: !show.macros.blackout)),
              ),
              const SizedBox(width: 4),
              _Held(
                label: 'STROBE',
                lit: m.strobe > 0,
                tooltip: 'Strobe while held (S on the stage page)',
                onDown: () => show.setMacros(show.macros.copyWith(strobe: 1)),
                onUp: () => show.setMacros(show.macros.copyWith(strobe: 0)),
              ),
              const SizedBox(width: 4),
              Pad(
                label: 'FREEZE',
                height: 30,
                lit: m.freeze,
                colour: Console.ink,
                tooltip: 'The picture held still (F on the stage page)',
                onTap: () => show.setMacros(show.macros.copyWith(freeze: !show.macros.freeze)),
              ),
              const SizedBox(width: 14),
              Knob(
                value: m.intensity,
                min: 0,
                max: 1,
                rest: 1,
                bipolar: false,
                size: 30,
                label: 'LEVEL',
                tooltip: 'Intensity: a master for everything',
                onChanged: (v) => show.setMacros(show.macros.copyWith(intensity: v)),
              ),
              const SizedBox(width: 8),
              Knob(
                value: m.colour,
                min: 0,
                max: 1,
                rest: 0,
                bipolar: false,
                size: 30,
                label: 'HUE',
                tooltip: 'A turn of the palette\'s hue',
                onChanged: (v) => show.setMacros(show.macros.copyWith(colour: v)),
              ),
            ]),
            const SizedBox(height: 6),
            _Flow(children: [
              Tooltip(
                  message: 'An effect over whatever comes, for now (a hold: let go above)',
                  child: Padding(padding: const EdgeInsets.only(right: 6), child: Text('HOLD AN EFFECT', style: Console.label(9)))),
              for (final f in const [Fx.kaleidoscope, Fx.slit, Fx.mosh, Fx.none]) ...[
                Pad(
                  label: f == Fx.none ? 'NONE' : _fxName(f).toUpperCase(),
                  height: 26,
                  lit: show.heldFx == f,
                  colour: Console.ink,
                  tooltip: show.heldFx == f
                      ? 'Held — tap to let each look have its own again'
                      : f == Fx.none
                          ? 'No effect over anything, for now'
                          : '${_fxName(f)} over whatever comes, for now',
                  onTap: () => show.holdFx(show.heldFx == f ? null : f),
                ),
                const SizedBox(width: 2),
              ],
            ]),
            const SizedBox(height: 6),
            _Flow(children: [
              Pad(
                label: 'MILKDROP UNDER',
                height: 26,
                lit: milk,
                colour: Console.ink,
                tooltip: milk
                    ? 'MilkDrop under every scene for now — tap to let the rotation choose the backgrounds again'
                    : 'MilkDrop under every scene for now, whatever the rotation says (a hold: let go above)',
                onTap: () => show.holdGround(milk ? null : 'milk'),
              ),
              const SizedBox(width: 14),
              Tooltip(
                  message: 'When what you put on lands: a look from a scene\'s page, a favourite',
                  child: Padding(padding: const EdgeInsets.only(right: 6), child: Text('LAND ON', style: Console.label(9)))),
              for (final q in Quantise.values) ...[
                Pad(
                  label: switch (q) { Quantise.now => 'NOW', Quantise.beat => 'BEAT', Quantise.bar => 'BAR', Quantise.phrase => 'PHRASE' },
                  height: 24,
                  lit: show.pool.quantise == q,
                  colour: Console.quiet,
                  tooltip: 'What you put on lands ${switch (q) {
                    Quantise.now => 'at once',
                    Quantise.beat => 'on the next beat',
                    Quantise.bar => 'on the next bar',
                    Quantise.phrase => 'on the next phrase'
                  }} (at once while nothing plays)',
                  onTap: () => show.setPool(show.pool.copyWith(quantise: q)),
                ),
                const SizedBox(width: 2),
              ],
            ]),
          ]);
        },
      );
}

/// A pad that is on while the pointer is down.
class _Held extends StatelessWidget {
  const _Held({required this.label, required this.lit, required this.tooltip, required this.onDown, required this.onUp});
  final String label, tooltip;
  final bool lit;
  final VoidCallback onDown, onUp;

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (_) => onDown(),
        onPointerUp: (_) => onUp(),
        onPointerCancel: (_) => onUp(),
        child: Pad(label: label, height: 30, lit: lit, colour: Console.ink, tooltip: tooltip, onTap: () {}),
      );
}
