// The sets, over the rotation: the show as the hands set it up — how often everything
// comes, the effects, the director's temper, the knobs, the finish — named and kept,
// switched between in a tap (state/show/show_snapshots.dart). Each one a chip — this
// device's, then the shared ones (every WetOwl account's, a figure of two beside the
// name) — the one on lit, a dot after its name where the show has changed since. SAVE
// puts the show over the one on (a shared one: over everyone's, unless someone saved
// it since — then theirs or ours); SAVE AS keeps it as a new one; the menu shares one
// with everyone, takes it away again, renames and forgets.
//
// Switching away from a show not saved puts it aside, with an UNDO.
part of 'show_room.dart';

class _SetBar extends StatefulWidget {
  const _SetBar({required this.show});
  final ShowEngine show;

  @override
  State<_SetBar> createState() => _SetBarState();
}

class _SetBarState extends State<_SetBar> {
  SnapshotShelf get shelf => widget.show.snapshots;

  @override
  void initState() {
    super.initState();
    shelf.hold();
  }

  @override
  void dispose() {
    shelf.release();
    super.dispose();
  }

  void _say(String words, {SnackBarAction? action}) => ScaffoldMessenger.of(context).say(snack(Text(words), action: action));

  /// The setup and the set on, as they are: what UNDO goes back to.
  ({ShowSetup setup, ShowSnapshot? on}) get _now => (setup: widget.show.pool.setup, on: shelf.on);

  void _back(({ShowSetup setup, ShowSnapshot? on}) was) {
    final show = widget.show;
    show.setDoc(show.doc.copyWith(pool: show.pool.withSetup(was.setup), snapshot: was.on, clearSnapshot: was.on == null));
  }

  void _switch(ShowSnapshot? to) {
    final was = _now;
    final lost = shelf.changed;
    final from = shelf.on?.name;
    if (to == null) {
      shelf.useShipped();
    } else {
      shelf.use(to);
    }
    if (lost) {
      _say(from == null ? 'Your changes were put aside' : 'Your changes to $from were not saved',
          action: SnackBarAction(label: 'UNDO', onPressed: () => _back(was)));
    }
  }

  Future<void> _saveAs() async {
    final name = await promptForName(context, 'Save the show as a set', '', 'Name',
        'How often everything comes, the effects, the director\'s temper, the knobs and the finish: switch back to it in a tap.');
    if (name == null || name.trim().isEmpty || !mounted) return;
    shelf.saveAs(name);
  }

  Future<void> _save({ShowSnapshot? over}) async {
    try {
      await shelf.save(over: over);
    } on SnapshotConflict catch (e) {
      if (!mounted) return;
      final theirs = e.theirs;
      final pick = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${theirs.name} has changed'),
          content: Text('${theirs.updatedBy ?? 'Someone'} saved it since you switched to it. Take theirs, or save yours over it?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, 'theirs'), child: const Text('Take theirs')),
            FilledButton(onPressed: () => Navigator.pop(context, 'ours'), child: const Text('Save over it')),
          ],
        ),
      );
      if (pick == 'theirs') shelf.use(theirs);
      if (pick == 'ours') await _save(over: theirs);
    } catch (_) {
      if (mounted) _say(shelf.trouble ?? 'Could not save it');
    }
  }

  Future<void> _menu(String what) async {
    if (what == 'reload') return shelf.refresh();
    final s = shelf.on;
    if (s == null) return;
    try {
      switch (what) {
        case 'rename':
          final name = await promptForName(context, 'Rename', s.name);
          if (name != null && name.trim().isNotEmpty) shelf.rename(s, name);
        case 'share':
          if (shelf.changed) await _save();
          final shared = await shelf.share(shelf.on!);
          _say('${shared.name} is shared: every WetOwl account can switch to it and save over it');
        case 'unshare':
          await shelf.unshare(s);
          _say('${s.name} is no longer shared: kept on this device');
        case 'forget':
          final was = (kept: shelf.kept, now: _now);
          shelf.forget(s);
          _say('${s.name} forgotten (the show stays as it is)',
              action: SnackBarAction(label: 'UNDO', onPressed: () {
                final show = widget.show;
                show.setDoc(show.doc.copyWith(snapshots: was.kept, snapshot: was.now.on));
              }));
      }
    } catch (_) {
      if (mounted) _say(shelf.trouble ?? 'That did not work');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([widget.show, shelf]),
        builder: (context, _) {
          final on = shelf.on;
          final changed = shelf.changed;
          Widget chip(ShowSnapshot? s) {
            final lit = s == null ? on == null : on?.id == s.id;
            final name = s?.name ?? 'As shipped';
            return Padding(
              padding: const EdgeInsets.only(right: 4),
              child: IntrinsicWidth(
                child: Pad(
                  icon: s != null && s.shared ? Icons.group_outlined : null,
                  label: '$name${lit && changed ? ' •' : ''}',
                  height: 24,
                  lit: lit,
                  colour: lit ? Console.a : Console.ink,
                  tooltip: s == null
                      ? 'No set: the show as the app came'
                      : s.shared
                          ? 'Shared by ${s.mine ? 'you' : s.owner ?? 'someone'}${s.updatedBy != null ? ', last saved by ${s.updatedBy}' : ''}'
                          : 'On this device',
                  onTap: lit ? null : () => _switch(s),
                ),
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(children: [
              Text('SET', style: Console.label(9, color: Console.ink)),
              const SizedBox(width: 8),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    chip(null),
                    for (final s in shelf.kept) chip(s),
                    for (final s in shelf.shared) chip(s),
                    if (shelf.loading) Padding(padding: const EdgeInsets.only(left: 4), child: Text('…', style: Console.label(10))),
                    if (shelf.trouble != null && !shelf.loading)
                      Tooltip(message: shelf.trouble!, child: Icon(Icons.cloud_off, size: 14, color: Console.faint)),
                  ]),
                ),
              ),
              const SizedBox(width: 6),
              IntrinsicWidth(
                child: Pad(
                  label: 'SAVE',
                  height: 24,
                  lit: on != null && changed,
                  colour: Console.a,
                  tooltip: on == null
                      ? 'Switch to a set or SAVE AS one first'
                      : on.shared
                          ? 'The show as it is over ${on.name}, for everyone'
                          : 'The show as it is over ${on.name}',
                  onTap: on != null && changed ? () => unawaited(_save()) : null,
                ),
              ),
              const SizedBox(width: 4),
              IntrinsicWidth(
                child: Pad(label: 'SAVE AS', height: 24, colour: Console.ink, tooltip: 'Keep the show as it is as a new set', onTap: () => unawaited(_saveAs())),
              ),
              PopupMenuButton<String>(
                tooltip: 'The set on',
                icon: Icon(Icons.more_vert, size: 18, color: Console.quiet),
                onSelected: (w) => unawaited(_menu(w)),
                itemBuilder: (context) => [
                  if (on != null && !on.shared) const PopupMenuItem(value: 'share', child: Text('Share with everyone')),
                  if (on != null && on.shared && on.mine) const PopupMenuItem(value: 'unshare', child: Text('Stop sharing (keep it here)')),
                  if (on != null && !on.shared) const PopupMenuItem(value: 'rename', child: Text('Rename')),
                  if (on != null && !on.shared) const PopupMenuItem(value: 'forget', child: Text('Forget')),
                  const PopupMenuItem(value: 'reload', child: Text('List the shared ones again')),
                ],
              ),
            ]),
          );
        },
      );
}
