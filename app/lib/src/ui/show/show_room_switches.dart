// ON/OFF: every single thing the show is made of — each scene, each style of the
// dancers, the flock and the words, each treatment, each background, each way of
// blending — with a switch. Off is gone everywhere until switched back on: the
// director never puts it on, the clocks never pick it, the rules never blend that
// way, and it leaves the strips, the grid and OTHER BLEND. Not pairs (that is the
// RULES grid): the parts themselves. Kept in the pool's `off` set (show_pool.dart):
// `look.<id>`, `style.<figure>.<name>`, `treatment.<name>`, `ground.<kind>`,
// `blend.<mode>`.
part of 'show_room.dart';

class _SwitchesTab extends StatelessWidget {
  const _SwitchesTab({required this.show, required this.kit});
  final ShowEngine show;
  final StageKit? kit;

  static const _grounds = [Ground.milk, Ground.field, Ground.wash, Ground.pulse, Ground.camera, Ground.cover];

  /// Every way but as drawn (always on: a scene on black is drawn so).
  static final _blends = [
    for (final m in GroundMode.values)
      if (m != GroundMode.over) m
  ];

  @override
  Widget build(BuildContext context) {
    final book = kit?.book;
    if (book == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: show,
      builder: (context, _) {
        final pool = show.pool;
        void set(String key, bool on) {
          feel(Feel.pick);
          show.setPool(pool.withOff(key, !on));
        }

        final scenes = book.scenes.values.toList()..sort((a, b) => a.name.compareTo(b.name));
        Widget section(String title, String hint, List<(String key, bool on)> items, List<Widget> chips, {void Function()? allOn}) {
          final n = items.where((i) => i.$2).length;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(title, style: Console.label(10, color: Console.ink)),
                const SizedBox(width: 8),
                Text('$n of ${items.length} on', style: TextStyle(fontSize: 10.5, color: n < items.length ? Console.a : Console.faint)),
                const SizedBox(width: 8),
                Expanded(child: Text(hint, style: TextStyle(fontSize: 10, color: Console.faint), maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (n < items.length)
                  IntrinsicWidth(
                    child: Pad(
                      label: 'ALL ON',
                      height: 22,
                      colour: Console.quiet,
                      onTap: allOn ??
                          () {
                            var p = pool;
                            for (final (k, _) in items) {
                              p = p.withOff(k, false);
                            }
                            show.setPool(p);
                          },
                    ),
                  ),
              ]),
              const SizedBox(height: 5),
              Wrap(spacing: 5, runSpacing: 5, children: chips),
            ]),
          );
        }

        Widget styles(Figure kind, String title) {
          final names = _stylesOf(kind);
          return section(
            title,
            kind == Figure.dancers || kind == Figure.birds ? 'a treatment switched off goes from here too' : '',
            [for (final s in names) ('style.${kind.name}.$s', pool.styleOn(kind, s))],
            [
              for (final s in names)
                _Switch(
                  label: s,
                  on: pool.styleOn(kind, s),
                  tip: pool.isOn('style.${kind.name}.$s') && !pool.isOn('treatment.$s') ? 'off with the treatment $s' : null,
                  onTap: () {
                    feel(Feel.pick);
                    show.setPool(pool.withStyle(kind, s, !pool.styleOn(kind, s)));
                  },
                ),
            ],
            allOn: () {
              var p = pool;
              for (final s in names) {
                p = p.withStyle(kind, s, true);
              }
              show.setPool(p);
            },
          );
        }

        return ListView(key: const ValueKey('switches'), children: [
          Text(
            'Every part of the show, one by one. Switched off, a thing is gone everywhere — the show never uses it, '
            'and it leaves the pictures to pick from and the RULES grid — until you switch it back on here.',
            style: TextStyle(fontSize: 11, color: Console.quiet, height: 1.35),
          ),
          const SizedBox(height: 10),
          section('SCENES', '', [
            for (final s in scenes) ('look.${s.id}', pool.isOn('look.${s.id}'))
          ], [
            for (final s in scenes) _Switch(label: s.name, on: pool.isOn('look.${s.id}'), onTap: () => set('look.${s.id}', !pool.isOn('look.${s.id}'))),
          ]),
          styles(Figure.dancers, 'DANCER STYLES'),
          styles(Figure.birds, 'FLOCK LOOKS'),
          styles(Figure.words, 'LYRICS FACES'),
          section('TREATMENTS', 'on every scene, and the dancers\' and the flock\'s looks of the same name', [
            for (final t in imageTreatments) ('treatment.${t.name}', pool.isOn('treatment.${t.name}'))
          ], [
            for (final t in imageTreatments)
              _Switch(label: t.name, on: pool.isOn('treatment.${t.name}'), onTap: () => set('treatment.${t.name}', !pool.isOn('treatment.${t.name}'))),
          ]),
          section('BACKGROUNDS', 'black is always there', [
            for (final g in _grounds) ('ground.${g.name}', pool.isOn('ground.${g.name}'))
          ], [
            for (final g in _grounds)
              _Switch(label: _groundWord(g), on: pool.isOn('ground.${g.name}'), onTap: () => set('ground.${g.name}', !pool.isOn('ground.${g.name}'))),
          ]),
          section('BLENDS', 'as drawn is always there; off, a rule\'s next way is used instead', [
            for (final m in _blends) ('blend.${m.name}', pool.blendOn(m))
          ], [
            for (final m in _blends)
              _Switch(
                label: m.name,
                on: pool.blendOn(m),
                swatch: m,
                onTap: () => set('blend.${m.name}', !pool.blendOn(m)),
              ),
          ]),
        ]);
      },
    );
  }
}

/// One switch: its name (and the blend's swatch), lit on, struck through off.
class _Switch extends StatelessWidget {
  const _Switch({required this.label, required this.on, required this.onTap, this.swatch, this.tip});
  final String label;
  final bool on;
  final VoidCallback onTap;
  final GroundMode? swatch;
  final String? tip;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: '$label: ${on ? 'on' : 'off — gone everywhere'}${tip != null ? ' ($tip)' : ''} · a tap: ${on ? 'off' : 'on'}',
        waitDuration: const Duration(milliseconds: 600),
        child: InkWell(
          borderRadius: BorderRadius.circular(5),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(5, 4, 8, 4),
            decoration: BoxDecoration(
              color: on ? Console.raised : Console.ground,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: on ? Console.line : Console.ground),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(on ? Icons.check_box : Icons.check_box_outline_blank, size: 14, color: on ? Console.a : Console.faint),
              const SizedBox(width: 5),
              if (swatch != null) ...[
                Opacity(opacity: on ? 1 : 0.35, child: ClipRRect(borderRadius: BorderRadius.circular(2), child: _BlendSwatch(swatch!, width: 26, height: 15))),
                const SizedBox(width: 5),
              ],
              Text(label,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: on ? Console.ink : Console.faint,
                    decoration: on ? null : TextDecoration.lineThrough,
                    decorationColor: Console.faint,
                  )),
            ]),
          ),
        ),
      );
}
