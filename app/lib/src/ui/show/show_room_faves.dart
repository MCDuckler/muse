// The FAVES tab: what was on the stage, kept with KEEP (or P on the stage page) as it
// was — combination, MilkDrop preset, camera, the 3D text's motion and look — whatever
// the rules say of it (state/show/show_faves.dart). A grid of their pictures, newest
// or best first, the fewest stars to show, one scene's or all; a tap puts one on the
// stage, held, until HOLD lets go (or NEXT, or another); ◀ ▶ step through them, for a
// quick look at each in turn; the stars under each rate it, one to five.
part of 'show_room.dart';

/// KEEP: what is on, kept, said with its stars to rate it there and then.
Future<void> _keepFave(BuildContext context, ShowEngine show, StageKit? kit) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final f = await keepFaveNow(show);
  if (f == null || messenger == null) return;
  var stars = 0;
  messenger.say(snack(
    StatefulBuilder(
      builder: (context, set) => Row(children: [
        Expanded(child: Text('Kept: ${_faveTitle(f, kit?.book)}', maxLines: 1, overflow: TextOverflow.ellipsis)),
        _Stars(
          stars: stars,
          size: 18,
          onChanged: (n) {
            set(() => stars = n);
            final now = show.faves.where((o) => o.id == f.id).firstOrNull;
            if (now != null) show.putFave(now.copyWith(stars: n));
          },
        ),
      ]),
    ),
    duration: kSnackWithAction,
  ));
}

/// A favourite's name: the hands', or what it is in a few words.
String _faveTitle(ShowFave f, SceneBook? book) {
  if (f.name.isNotEmpty) return f.name;
  final c = f.combo;
  return [
    _valueName(ComboAxis.scene, c.scene, book),
    if (c.style != 'raw') c.style,
    if (!c.world) _groundName(c.ground),
  ].join(' · ');
}

/// Everything a favourite keeps, in words, a line each.
String _faveWords(ShowFave f, SceneBook? book) {
  final c = f.combo;
  final t = f.type3d;
  return [
    '${_valueName(ComboAxis.scene, c.scene, book)}${c.style != 'raw' ? ' · ${c.style}' : ''}',
    if (!c.world) 'on ${_groundName(c.ground)} · ${_maskName(c.mask).toLowerCase()} · ${_mixName(c.mix).toLowerCase()}',
    if (f.milk != null) 'MilkDrop: ${f.milk}',
    if (f.shot != null) 'Camera: ${_shotName(f.shot!).toLowerCase()}',
    if (t != null)
      'Text: ${t.motions.map((m) => m.name).join()} · ${t.looks.map((l) => l.name).join()}${t.deforms.isEmpty ? '' : ' · ${t.deforms.map((d) => d.name).join(', ')}'}',
    'Kept ${_when(f.at)}',
  ].join('\n');
}

String _when(DateTime at) {
  final d = DateTime.now().difference(at);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays < 30) return '${d.inDays} d ago';
  return '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
}

class _FavesTab extends StatefulWidget {
  const _FavesTab({required this.show, required this.kit});
  final ShowEngine show;
  final StageKit? kit;

  @override
  State<_FavesTab> createState() => _FavesTabState();
}

class _FavesTabState extends State<_FavesTab> {
  ShowEngine get show => widget.show;

  /// Newest first, or the best.
  bool _best = false;

  /// The fewest stars to show (0: every one, the unrated too).
  int _least = 0;

  /// One scene's only; null: all.
  String? _scene;

  @override
  void initState() {
    super.initState();
    final p = show.doc.panel;
    _best = p['faves.best'] == true;
    _least = p['faves.least'] is num ? (p['faves.least'] as num).toInt().clamp(0, 5) : 0;
    unawaited(FaveThumbs.ready().then((_) {
      if (mounted) setState(() {});
      // The pictures of the ones forgotten before (kept for their UNDO), thrown away.
      return FaveThumbs.prune({for (final f in show.faves) f.id});
    }));
  }

  void _keep() => show.setDoc(show.doc.copyWith(panel: {...show.doc.panel, 'faves.best': _best, 'faves.least': _least}));

  List<ShowFave> get _shown {
    final out = [
      for (final f in show.faves)
        if (f.stars >= _least && (_scene == null || f.combo.scene == _scene)) f
    ];
    if (_best) out.sort((a, b) => b.stars != a.stars ? b.stars.compareTo(a.stars) : b.at.compareTo(a.at));
    return out;
  }

  /// The next one shown after the one on ([by] -1: before), put on.
  void _step(int by) {
    final list = _shown;
    if (list.isEmpty) return;
    final i = list.indexWhere((f) => f.id == show.faveOn?.id);
    final n = i < 0 ? (by > 0 ? 0 : list.length - 1) : (i + by) % list.length;
    show.playFave(list[n < 0 ? n + list.length : n]);
  }

  void _say(String words, {SnackBarAction? action}) => ScaffoldMessenger.of(context).say(snack(Text(words), action: action));

  Future<void> _menu(ShowFave f, String what) async {
    switch (what) {
      case 'rename':
        final name = await promptForName(context, 'Name it', f.name.isEmpty ? _faveTitle(f, widget.kit?.book) : f.name);
        if (name != null) show.putFave(f.copyWith(name: name.trim()));
      case 'forget':
        final was = show.faves;
        show.forgetFave(f.id);
        _say('${_faveTitle(f, widget.kit?.book)} forgotten',
            action: SnackBarAction(label: 'UNDO', onPressed: () => show.setDoc(show.doc.copyWith(faves: was))));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: show,
        builder: (context, _) {
          final book = widget.kit?.book;
          final all = show.faves;
          final shown = _shown;
          final on = show.faveOn;
          final scenes = <String>{for (final f in all) f.combo.scene}.toList();
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _Line(children: [
              Text('FAVOURITES', style: Console.label(10, color: Console.ink)),
              const SizedBox(width: 6),
              Text('${shown.length}${shown.length != all.length ? ' of ${all.length}' : ''}', style: Console.label(9)),
              const SizedBox(width: 12),
              _Word(
                  label: 'NEWEST',
                  lit: !_best,
                  tooltip: 'The last kept first',
                  onTap: () => setState(() {
                        _best = false;
                        _keep();
                      })),
              _Word(
                  label: 'BEST',
                  lit: _best,
                  tooltip: 'The most stars first',
                  onTap: () => setState(() {
                        _best = true;
                        _keep();
                      })),
              const SizedBox(width: 8),
              for (var n = 0; n <= 5; n++)
                _Word(
                  label: n == 0 ? 'ALL' : '${'★' * n}${n < 5 ? '+' : ''}',
                  lit: _least == n,
                  tooltip: n == 0 ? 'Every one, the unrated too' : 'Only those with $n star${n == 1 ? '' : 's'}${n < 5 ? ' or more' : ''}',
                  onTap: () => setState(() {
                    _least = n;
                    _keep();
                  }),
                ),
              const SizedBox(width: 8),
              Pad(
                  icon: Icons.chevron_left,
                  width: 26,
                  height: 24,
                  colour: Console.ink,
                  tooltip: 'The one before, on the stage',
                  onTap: shown.isEmpty ? null : () => _step(-1)),
              const SizedBox(width: 2),
              Pad(
                  icon: Icons.chevron_right,
                  width: 26,
                  height: 24,
                  colour: Console.ink,
                  tooltip: 'The next one, on the stage',
                  onTap: shown.isEmpty ? null : () => _step(1)),
            ]),
            if (scenes.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _Line(children: [
                  _Word(label: 'ANY SCENE', lit: _scene == null, onTap: () => setState(() => _scene = null)),
                  for (final s in scenes)
                    _Word(
                        label: _valueName(ComboAxis.scene, s, book), lit: _scene == s, onTap: () => setState(() => _scene = _scene == s ? null : s)),
                ]),
              ),
            if (on != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Icon(Icons.star, size: 14, color: Console.a),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('On the stage, held: ${_faveTitle(on, book)}',
                        style: TextStyle(color: Console.ink, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  IntrinsicWidth(
                    child: Pad(label: 'LET GO', height: 24, colour: Console.a, tooltip: 'Back to the rotation', onTap: () => show.holdScene(false)),
                  ),
                ]),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: all.isEmpty
                  ? Center(
                      child: Text(
                        'Nothing kept yet.\nKEEP under the picture (P on the stage page) keeps what is on the stage as it is —\n'
                        'the combination, the MilkDrop preset, the camera — whatever the rules say of it.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Console.quiet, fontSize: 12, height: 1.5),
                      ),
                    )
                  : shown.isEmpty
                      ? Center(child: Text('None with these stars.', style: TextStyle(color: Console.quiet, fontSize: 12)))
                      : LayoutBuilder(builder: (context, c) {
                          const gap = 8.0, least = 190.0;
                          final cols = math.max(1, ((c.maxWidth + gap) / (least + gap)).floor());
                          final w = (c.maxWidth - gap * (cols - 1)) / cols;
                          return GridView.builder(
                            itemCount: shown.length,
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: cols, crossAxisSpacing: gap, mainAxisSpacing: gap, mainAxisExtent: w * 9 / 16 + 48),
                            itemBuilder: (context, i) {
                              final f = shown[i];
                              return _FaveTile(
                                key: ValueKey(f.id),
                                fave: f,
                                book: book,
                                on: on?.id == f.id,
                                onPlay: () => on?.id == f.id ? show.holdScene(false) : show.playFave(f),
                                onStars: (n) => show.putFave(f.copyWith(stars: n)),
                                onMenu: (w) => unawaited(_menu(f, w)),
                              );
                            },
                          );
                        }),
            ),
          ]);
        },
      );
}

class _FaveTile extends StatelessWidget {
  const _FaveTile(
      {super.key, required this.fave, required this.book, required this.on, required this.onPlay, required this.onStars, required this.onMenu});
  final ShowFave fave;
  final SceneBook? book;
  final bool on;
  final VoidCallback onPlay;
  final ValueChanged<int> onStars;
  final ValueChanged<String> onMenu;

  @override
  Widget build(BuildContext context) {
    final picture = FaveThumbs.image(fave.id);
    final thumb = thumbOf(fave.combo.scene);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AspectRatio(
        aspectRatio: 16 / 9,
        child: Tooltip(
          message: '${_faveWords(fave, book)}\n\n${on ? 'Tap: back to the rotation' : 'Tap: on the stage, held'}',
          waitDuration: const Duration(milliseconds: 600),
          child: Material(
            color: Colors.black,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6), side: BorderSide(color: on ? Console.a : Console.line, width: on ? 2 : 1)),
            child: InkWell(
              onTap: () {
                feel(Feel.commit);
                onPlay();
              },
              child: Stack(fit: StackFit.expand, children: [
                if (picture != null)
                  Image(image: picture, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium)
                else if (thumb != null)
                  Opacity(opacity: 0.6, child: Image.asset(thumb, fit: BoxFit.cover))
                else
                  Center(child: Icon(Icons.star_border, color: Console.faint)),
                if (fave.milk != null)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Tooltip(message: fave.milk!, child: Icon(Icons.blur_on, size: 14, color: Colors.white.withValues(alpha: 0.8))),
                  ),
                if (on)
                  Positioned(
                    left: 4,
                    top: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(color: Console.a, borderRadius: BorderRadius.circular(3)),
                      child: Text('ON', style: Console.label(8, color: Colors.black)),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
      const SizedBox(height: 3),
      Row(children: [
        Expanded(
          child: Text(_faveTitle(fave, book),
              style: TextStyle(color: on ? Console.a : Console.ink, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        SizedBox(
          width: 22,
          height: 20,
          child: PopupMenuButton<String>(
            padding: EdgeInsets.zero,
            iconSize: 16,
            tooltip: 'Name it, forget it',
            icon: Icon(Icons.more_vert, size: 16, color: Console.quiet),
            onSelected: onMenu,
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'rename', child: Text('Name it')),
              PopupMenuItem(value: 'forget', child: Text('Forget')),
            ],
          ),
        ),
      ]),
      _Stars(stars: fave.stars, onChanged: onStars),
    ]);
  }
}

/// One to five stars, tapped: the star tapped (the one it has: none).
class _Stars extends StatelessWidget {
  const _Stars({required this.stars, required this.onChanged, this.size = 16});
  final int stars;
  final double size;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var n = 1; n <= 5; n++)
          Tooltip(
            message: n == stars ? 'Not rated' : '$n star${n == 1 ? '' : 's'}',
            waitDuration: const Duration(milliseconds: 700),
            child: InkResponse(
              radius: size * 0.8,
              onTap: () {
                feel(Feel.pick);
                onChanged(n == stars ? 0 : n);
              },
              child: Padding(
                padding: const EdgeInsets.only(right: 1),
                child: Icon(n <= stars ? Icons.star_rounded : Icons.star_outline_rounded, size: size, color: n <= stars ? Console.a : Console.faint),
              ),
            ),
          ),
      ]);
}
