// A scene's page, from the ROTATION: how often it comes; its styles, each a fader
// (with its knobs where a shader draws it); the backgrounds, masks and blends — as
// every scene has them, or its own; the grid of its looks, style by background, each
// shown as the stage blends it and judged in a tap (show_room_grid.dart); its camera's
// framings (the dancers', the flock's); and what it shows (who dances and their moves,
// the 3D text's words and ways). PLAY IT puts one of its looks on; COPY FROM makes it
// like another scene.
part of 'show_room.dart';

class _ScenePage extends StatefulWidget {
  const _ScenePage({super.key, required this.show, required this.kit, required this.scene, required this.onScene, required this.onTab});
  final ShowEngine show;
  final StageKit kit;
  final String scene;
  final void Function(String?) onScene;
  final void Function(ShowTab) onTab;

  @override
  State<_ScenePage> createState() => _ScenePageState();
}

class _ScenePageState extends State<_ScenePage> {
  ShowEngine get show => widget.show;
  String get id => widget.scene;

  /// The style whose knobs are open.
  String? _knobs;

  @override
  void initState() {
    super.initState();
    _Stills.shared
      ..hold()
      ..addListener(_redraw);
  }

  @override
  void dispose() {
    _Stills.shared
      ..removeListener(_redraw)
      ..release();
    super.dispose();
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  /// One of its looks on now, as likely as the plan says (held, landing on LAND ON).
  void _play(PlanShares shares) {
    final looks = shares.looksOf(id).entries.where((e) => e.value > 0).map((e) => (e.key, e.value)).toList();
    final kind = show.kinds[id] ?? Figure.none;
    final pick = pickByWeight(looks, math.Random().nextDouble()) ?? combosOf(id, kind, grounds: const ['black']).first;
    show.play(pick);
  }

  void _copyFrom(String from) {
    final before = show.pool.plan;
    final kind = show.kinds[id] ?? Figure.none;
    show.setPlan(before.copyScene(from, id, stylesOfFigure(kind)));
    final name = widget.kit.book[from]?.name ?? from;
    ScaffoldMessenger.of(context).say(snack(
      Text('${widget.kit.book[id]?.name ?? id} is like $name now: its styles, its own backgrounds, masks and blends, the looks judged'),
      action: SnackBarAction(label: 'UNDO', onPressed: () => show.setPlan(before)),
    ));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: show,
        builder: (context, _) {
          final book = widget.kit.book;
          final scene = book[id];
          if (scene == null) return const SizedBox.shrink();
          final plan = show.pool.plan;
          final sp = plan.of(id);
          final kind = scene.look.rig.figure.kind;
          final styles = stylesOfFigure(kind);
          final shares = _sharesOf(show);
          final world = worldScenes.contains(id) || kind == Figure.none;
          final live = show.combo?.scene == id ? show.combo : null;
          final shots = shotsOfFigure(kind);
          final others = [for (final s in _scenesInOrder(book)) if (s.id != id && !worldScenes.contains(s.id) && s.look.rig.figure.kind != Figure.none) s];
          return ListView(key: const ValueKey('scene page'), children: [
            // The heading: back, the scene, play it, copy from.
            Row(children: [
              Pad(icon: Icons.chevron_left, label: 'ROTATION', height: 28, colour: Console.ink, tooltip: 'Back to every scene', onTap: () => widget.onScene(null)),
              const SizedBox(width: 12),
              if (thumbOf(id) case final t?)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: ClipRRect(borderRadius: BorderRadius.circular(3), child: Image.asset(t, width: 56, height: 32, fit: BoxFit.cover)),
                ),
              Expanded(
                child: Text(scene.name.toUpperCase(), style: Console.label(14, color: Console.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (!world && others.isNotEmpty)
                PopupMenuButton<String>(
                  tooltip: 'Make it like another scene: its styles, its own backgrounds, masks and blends, the looks judged',
                  onSelected: _copyFrom,
                  itemBuilder: (context) => [
                    for (final s in others) PopupMenuItem(value: s.id, child: Text('Like ${s.name}')),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('COPY FROM', style: Console.label(9, color: Console.ink)),
                      Icon(Icons.arrow_drop_down, size: 18, color: Console.quiet),
                    ]),
                  ),
                ),
              IntrinsicWidth(
                child: Pad(
                  icon: Icons.play_arrow,
                  label: 'PLAY IT',
                  height: 28,
                  colour: Console.a,
                  tooltip: 'One of its looks on the stage, held until you let go (on the LAND ON)',
                  onTap: () => _play(shares),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            _LevelRow(
              key: const ValueKey('scene level'),
              label: 'How often',
              picture: ColoredBox(color: Console.ground, child: Icon(Icons.equalizer, size: 18, color: Console.quiet)),
              level: sp.level,
              muted: sp.muted,
              share: shares.scenes[id],
              shareTip: 'Of the night, about',
              note: sp.weight > 0 && !shares.anyOn(id) ? 'none of its looks can come: turn a style, a background or a look on below' : null,
              onLevel: (v) => show.setPlan(plan.withScene(id, level: v)),
              onMuted: (m) {
                var p = plan;
                if (!m && sp.level <= 0) p = p.withScene(id, level: 1);
                show.setPlan(p.withScene(id, muted: m));
                if (m && show.state.scene == id) show.stepOn();
              },
            ),
            // The styles.
            if (styles.length > 1 || styles.first != 'raw') ...[
              _Head('STYLES', hint: 'how it is drawn · of its time'),
              for (final st in styles) ...[
                _LevelRow(
                  key: ValueKey('style:$st'),
                  label: st == 'raw' ? 'as drawn' : st,
                  picture: _stylePicture(kind, st),
                  level: plan.faderIn(id, PlanAxis.style, st),
                  muted: plan.mutedIn(id, PlanAxis.style, st),
                  share: shares.within(id, PlanAxis.style, st),
                  shareTip: 'Of its time, about',
                  live: live?.style == st,
                  note: isWorld(id, kind, st) && !world ? 'a world of its own: its own background' : null,
                  onLevel: (v) => show.setPlan(plan.withIn(id, PlanAxis.style, st, level: v)),
                  onMuted: (m) {
                    var p = plan;
                    if (!m && plan.faderIn(id, PlanAxis.style, st) <= 0) p = p.withIn(id, PlanAxis.style, st, level: 1);
                    show.setPlan(p.withIn(id, PlanAxis.style, st, muted: m));
                  },
                  extra: treatmentTunes.containsKey(st)
                      ? Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Pad(
                            icon: Icons.tune,
                            width: 28,
                            height: 26,
                            lit: _knobs == st,
                            colour: Console.quiet,
                            tooltip: 'Its knobs',
                            onTap: () => setState(() => _knobs = _knobs == st ? null : st),
                          ),
                        )
                      : const SizedBox(width: 32),
                ),
                if (_knobs == st) Padding(padding: const EdgeInsets.only(left: 64, bottom: 6), child: _TuneLine(show: show, treatment: st, label: st.toUpperCase())),
              ],
            ],
            // The backgrounds, masks and blends (not for a world: it has its own), and
            // the effects: as every scene has them, or its own.
            for (final a in sharedAxes)
              if (!world || a == PlanAxis.fx) ..._sharedRows(a, plan, shares, live),
            // The grid of its looks.
            _Head('ITS LOOKS',
                hint: world
                    ? 'each style a world of its own · tap: never, or back'
                    : 'style × background, blended the stage\'s way · tap: never, or back · right-click or hold: less, more, each mask and blend'),
            _LooksGrid(show: show, kit: widget.kit, scene: id, kind: kind, shares: shares),
            // The camera.
            if (shots.isNotEmpty) ...[
              _Head('CAMERA', hint: 'how it is framed at each cut, while it is on — never how often it comes'),
              for (final k in shots)
                () {
                  final name = k.substring(k.indexOf('.') + 1);
                  final total = shots.fold(0.0, (t, x) => t + plan.shotLevel(id, x.substring(x.indexOf('.') + 1)));
                  return _LevelRow(
                    key: ValueKey('shot:$name'),
                    label: _shotName(k),
                    picture: ColoredBox(color: Console.ground, child: Icon(_shotIcon(k), size: 18, color: Console.quiet)),
                    level: plan.faderIn(id, PlanAxis.shot, name),
                    muted: plan.mutedIn(id, PlanAxis.shot, name),
                    share: total <= 0 ? 0 : plan.shotLevel(id, name) / total,
                    shareTip: 'Of the cuts, against the others (the mood and the company lean it too)',
                    live: StylePool.shotNow[kind] == name && live != null,
                    onLevel: (v) => show.setPlan(plan.withIn(id, PlanAxis.shot, name, level: v)),
                    onMuted: (m) => show.setPlan(plan.withIn(id, PlanAxis.shot, name, muted: m)),
                  );
                }(),
            ],
            // What it shows.
            ..._content(kind),
            const SizedBox(height: 16),
          ]);
        },
      );

  /// A style's picture: its still, where there is one.
  Widget? _stylePicture(Figure kind, String style) {
    final img = _Stills.shared.figure(kind, style);
    return img == null ? null : RawImage(image: img, fit: BoxFit.cover);
  }

  List<Widget> _sharedRows(PlanAxis a, ShowPlan plan, PlanShares shares, Combo? live) {
    final own = plan.owns(id, a);
    final (word, hint) = switch (a) {
      PlanAxis.ground => ('BACKGROUNDS', 'what is under it'),
      PlanAxis.mask => ('MASKS', 'where the background shows'),
      PlanAxis.fx => ('EFFECTS', 'what is done to it over time and space'),
      _ => ('BLENDS', 'how it and the background meet'),
    };
    final values = axisValues(a);
    String label(String v) => switch (a) {
          PlanAxis.ground => _groundName(v),
          PlanAxis.mask => _maskName(Mask.values.byName(v)),
          PlanAxis.fx => _fxName(Fx.values.byName(v)),
          _ => _mixName(Mix.values.byName(v)),
        };
    final toggle = [
      _Word(
        label: 'AS EVERYWHERE',
        lit: !own,
        tooltip: 'The ${word.toLowerCase()} every scene shares (the ROTATION\'s)',
        onTap: () => show.setPlan(plan.withOwn(id, a, false)),
      ),
      _Word(
        label: 'ITS OWN',
        lit: own,
        tooltip: 'Its own ${word.toLowerCase()}: the shared ones copied, to be set for it alone',
        onTap: () => show.setPlan(plan.withOwn(id, a, true)),
      ),
    ];
    if (!own) {
      final on = [
        for (final v in values)
          if (plan.levelIn(id, a, v) > 0 && shares.within(id, a, v) > 0) '${label(v)} ${shareWord(shares.within(id, a, v))}',
      ];
      return [
        _Head(word, hint: hint, trailing: toggle),
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 4),
          child: Text(on.isEmpty ? 'none on' : on.join(' · '), style: TextStyle(fontSize: 11.5, color: Console.quiet)),
        ),
      ];
    }
    return [
      _Head(word, hint: hint, trailing: toggle),
      for (final v in values)
        _LevelRow(
          key: ValueKey('own ${a.name}:$v'),
          label: label(v),
          thumb: a == PlanAxis.ground ? _groundThumb(v) : null,
          swatch: a == PlanAxis.ground ? _groundSwatch(v) : null,
          picture: switch (a) {
            PlanAxis.mask => _ComboSwatch(Mask.values.byName(v), Mix.normal),
            PlanAxis.mix => _ComboSwatch(Mask.none, Mix.values.byName(v)),
            PlanAxis.fx => _FxIcon(Fx.values.byName(v)),
            _ => null,
          },
          level: plan.faderIn(id, a, v),
          muted: plan.mutedIn(id, a, v),
          share: shares.within(id, a, v),
          shareTip: 'Of its time, about',
          live: live != null && (a == PlanAxis.fx || !live.world) && planValue(live, a) == v,
          onLevel: (x) => show.setPlan(plan.withIn(id, a, v, level: x)),
          onMuted: (m) => show.setPlan(plan.withIn(id, a, v, muted: m)),
        ),
    ];
  }

  List<Widget> _content(Figure kind) => switch (kind) {
        Figure.dancers => [
            const _Head('WHO DANCES', hint: 'a name dances alone · a switch off keeps them out of the mix'),
            _Dancers(show: show),
            const _Head('THE MOVES', hint: 'every move of the bank: watch one, switch it off, star it'),
            SizedBox(height: 560, child: MovesBrowser(show: show)),
          ],
        Figure.type3d => [
            const _Head('THE TEXT', hint: 'its words and ways'),
            _Type3dTab(show: show),
          ],
        Figure.none when id == 'milk' => [
            const _Head('THE PRESETS', hint: 'MilkDrop\'s own, and its director'),
            Align(
              alignment: Alignment.centerLeft,
              child: IntrinsicWidth(
                child: Pad(label: 'MILKDROP ›', height: 28, colour: Console.ink, tooltip: 'The presets, their director, the maker', onTap: () => widget.onTab(ShowTab.milkdrop)),
              ),
            ),
          ],
        _ => const [],
      };
}

/// Who dances: a name alone, or a mix of the ones switched on.
class _Dancers extends StatelessWidget {
  const _Dancers({required this.show});
  final ShowEngine show;

  @override
  Widget build(BuildContext context) {
    final pool = show.pool;
    final lead = pool.dancer;
    return _Line(children: [
      _Word(label: 'A MIX', lit: lead == null, tooltip: 'Each record its own lead, the others in the troupe', onTap: () => show.setPool(pool.copyWith(clearDancer: true))),
      const SizedBox(width: 6),
      for (final (id, name) in DanceModels.all) ...[
        _Word(
            label: name.toUpperCase(),
            lit: lead == id,
            off: !pool.isOn('dancer.$id'),
            tooltip: 'Only $name dances',
            onTap: () => show.setPool(pool.withOff('dancer.$id', false).copyWith(dancer: id))),
        Tooltip(
          message: pool.isOn('dancer.$id') ? 'On: may dance in the mix' : 'Off: never in the mix',
          child: Switch(
            value: pool.isOn('dancer.$id'),
            onChanged: (v) {
              var p = pool.withOff('dancer.$id', !v);
              if (!v && p.dancer == id) p = p.copyWith(clearDancer: true);
              show.setPool(p);
            },
          ),
        ),
        const SizedBox(width: 6),
      ],
    ]);
  }
}
