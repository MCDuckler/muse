import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'artwork.dart';
import '../state/app_state.dart';
import '../state/playlist_ticks.dart';
import 'snack.dart';

/// Ask for a name. Returns null when the user backs out, so callers can tell "cancel"
/// apart from "empty".
Future<String?> promptForName(BuildContext context, String title,
    [String initial = '',
    // Some answers are a name and some are a paste: a link, or the block of request
    // headers YouTube Music needs. One line is right for the first and useless for
    // the second.
    String hint = 'Name',
    String? help,
    bool multiline = false]) async {
  final controller = TextEditingController(text: initial);
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (help != null) ...[
            Text(help, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: controller,
            autofocus: true,
            maxLines: multiline ? 6 : 1,
            minLines: multiline ? 4 : 1,
            textInputAction:
                multiline ? TextInputAction.newline : TextInputAction.done,
            onSubmitted:
                multiline ? null : (v) => Navigator.pop(context, v),
            decoration: InputDecoration(hintText: hint),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save')),
      ],
    ),
  );
  final trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

Future<bool> confirm(BuildContext context, String title, String body) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
      ],
    ),
  );
  return ok ?? false;
}

/// Pick a playlist to add a track to, or make one on the spot — the common case is
/// "this song belongs somewhere I have not created yet".
Future<void> addToPlaylistSheet(
        BuildContext context, AppState app, Track track) =>
    addTracksToPlaylistSheet(context, app, [track]);

/// Put songs on playlists — one song or the eleven you have picked out, one list or
/// several, in a single pass.
///
/// It used to be one tap, one playlist, sheet closed: adding a song to three lists
/// meant opening the same sheet three times, and the sheet never said which lists
/// already had it, so the third tap was as likely to be a duplicate as an addition.
///
/// Now every playlist carries a tick showing what is already true — full, partly
/// (some of the songs picked out, not all), or empty — and the ticks are what you
/// change. Unticking a list that has the song takes it off, because a tick-box that
/// only goes one way is a button wearing a tick-box's clothes.
Future<void> addTracksToPlaylistSheet(
    BuildContext context, AppState app, List<Track> tracks) async {
  if (tracks.isEmpty) return;
  await app.refreshPlaylists();
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _PlaylistPicker(app: app, tracks: tracks),
  );
}

class _PlaylistPicker extends StatefulWidget {
  const _PlaylistPicker({required this.app, required this.tracks});
  final AppState app;
  final List<Track> tracks;

  @override
  State<_PlaylistPicker> createState() => _PlaylistPickerState();
}

class _PlaylistPickerState extends State<_PlaylistPicker> {
  late final PlaylistTicks _ticks = PlaylistTicks(songs: widget.tracks.length);
  bool _loading = true;
  bool _saving = false;

  List<Track> get _tracks => widget.tracks;
  List<int> get _ids => [for (final t in _tracks) t.id];
  List<int> get _lists => [for (final p in widget.app.playlists) p.id];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final held = await widget.app.api.playlistsHolding(_ids);
      if (mounted) setState(() { _ticks.held = held; _loading = false; });
    } catch (_) {
      // A sheet that will not draw because one extra request failed is worse than a
      // sheet with no ticks in it: adding still works.
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _apply() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final plan = _ticks.plan(_lists);
    final named = {for (final p in widget.app.playlists) p.id: p.name};
    var added = 0, removed = 0;
    String? last;
    try {
      for (final id in plan.add) {
        await widget.app.api.addToPlaylist(id, _ids);
        added++;
        last = named[id];
      }
      for (final id in plan.remove) {
        await widget.app.api.removeFromPlaylist(id, _ids);
        removed++;
        last = named[id];
      }
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      messenger.showSnackBar(snack(Text('$e')));
      return;
    }
    await widget.app.refreshPlaylists();
    // The hearts are a playlist too, and one of the lists here is it.
    await widget.app.refreshFavourites();
    if (!mounted) return;
    Navigator.of(context).pop();
    final what = _tracks.length == 1
        ? _tracks.first.displayTitle
        : '${_tracks.length} songs';
    final said = added + removed == 1
        ? (added == 1 ? 'Added to "$last"' : 'Taken off "$last"')
        : '$what: ${[
            if (added > 0) 'on $added lists',
            if (removed > 0) 'off $removed lists',
          ].join(', ')}';
    messenger.showSnackBar(snack(Text(said)));
  }

  @override
  Widget build(BuildContext context) {
    final many = _tracks.length > 1;
    final playlists = widget.app.playlists;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.72),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
              child: Row(
                children: [
                  Artwork(track: _tracks.first, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(many ? '${_tracks.length} songs' : _tracks.first.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall),
                        Text(
                            many
                                ? '${_tracks.first.displayTitle} and '
                                    '${_tracks.length - 1} more'
                                : _tracks.first.artistLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // "Done" closes and "Save 3" writes: the same button, because the
                  // question it answers is the same one — am I finished here.
                  FilledButton(
                    onPressed: _saving
                        ? null
                        : _ticks.changes(_lists) == 0
                            ? () => Navigator.of(context).pop()
                            : _apply,
                    child: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(_ticks.changes(_lists) == 0
                            ? 'Done'
                            : 'Save ${_ticks.changes(_lists)}'),
                  ),
                ],
              ),
            ),
            const Divider(),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  ListTile(
                    leading: const SizedBox(
                        width: 70,
                        child: Align(
                            alignment: Alignment.centerRight,
                            child: Icon(Icons.add))),
                    title: const Text('New playlist…'),
                    onTap: () async {
                      final name = await promptForName(context, 'New playlist');
                      if (name == null) return;
                      final made = await widget.app.api.createPlaylist(name);
                      await widget.app.api.addToPlaylist(made.id, _ids);
                      await widget.app.refreshPlaylists();
                      if (!context.mounted) return;
                      Navigator.of(context).pop();
                      ScaffoldMessenger.of(context)
                          .showSnackBar(snack(Text('Added to "$name"')));
                    },
                  ),
                  for (final p in playlists)
                    _PlaylistTick(
                      playlist: p,
                      state: _ticks.stateOf(p.id),
                      loading: _loading,
                      // A mirror of somebody else's list is a view, not a place to put
                      // things; the server says so and the tick should not pretend
                      // otherwise.
                      onTap: p.editable
                          ? () => setState(() => _ticks.toggle(p.id))
                          : null,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One playlist, with what is already true about it said in front of the name.
class _PlaylistTick extends StatelessWidget {
  const _PlaylistTick({
    required this.playlist,
    required this.state,
    required this.loading,
    this.onTap,
  });

  final Playlist playlist;

  /// true — every picked song is on it. null — some are. false — none.
  final bool? state;
  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final off = onTap == null;
    return ListTile(
      enabled: !off,
      leading: SizedBox(
        width: 70,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              child: loading
                  ? null
                  : off
                      ? Icon(Icons.lock_outline, size: 18, color: scheme.outline)
                      : Icon(
                          state == true
                              ? Icons.check_box
                              : state == null
                                  ? Icons.indeterminate_check_box
                                  : Icons.check_box_outline_blank,
                          size: 22,
                          color: state == false ? scheme.outline : scheme.primary,
                        ),
            ),
            const SizedBox(width: 6),
            PlaylistArt(playlist: playlist, size: 40),
          ],
        ),
      ),
      title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(off
          ? 'Mirrors ${playlist.kind} · make a copy to edit'
          : '${playlist.itemCount} tracks'),
      onTap: onTap,
    );
  }
}


/// A failure with a way out. A blank area and a spinner that never resolves is the
/// worst of the three things a failed load can look like.
class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = error is ApiException
        ? (error as ApiException).message
        : 'Could not load that';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off,
                size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

class EmptyHint extends StatelessWidget {
  const EmptyHint(
      {super.key, required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(body,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      );
}
