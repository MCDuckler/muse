import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/offline.dart';
import 'source_dot.dart';
import 'browse_page.dart';
import 'dialogs.dart';
import 'lyrics_sheet.dart';
import 'station.dart';
import 'snack.dart';

/// Everything you can do to one track, in one place.
///
/// These actions were scattered across three screens with different subsets, and the
/// two that had no home at all — going to the album or artist, and correcting bad
/// metadata — simply did not exist.
enum TrackAction { playNext, addToQueue, addToPlaylist, goToAlbum, goToArtist, lyrics, edit, retry, remove }

/// [queuePosition] is where this song sits in the queue being played, when that is
/// the list it was opened from. There, "play now" plays that row and "play next" moves
/// it — rather than both putting a second copy of a song that is already queued.
Future<void> showTrackSheet(
  BuildContext context,
  Track track, {
  VoidCallback? onRemove,
  VoidCallback? onChanged,
  int? queuePosition,
}) async {
  final app = context.read<AppState>();
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          _Header(track: track),
          const Divider(height: 1),
          // First, because it is the one thing here that is about the song rather than
          // about the queue, and the one most often wanted.
          Builder(builder: (context) {
            final on = context.watch<AppState>().isFavourite(track.id);
            return _item(
              sheet,
              on ? Icons.favorite : Icons.favorite_border,
              on ? 'Remove from favourites' : 'Add to favourites',
              () => app.toggleFavourite(track.id),
            );
          }),
          if (OfflineStore.supported)
            Builder(builder: (context) {
              final offline = context.watch<AppState>().offline;
              final here = offline.has(track.id);
              final coming = offline.isQueued(track.id);
              return _item(
                sheet,
                here
                    ? Icons.download_done
                    : coming
                        ? Icons.downloading
                        : Icons.download_outlined,
                here
                    ? 'Kept on this device'
                    : coming
                        ? 'Being kept…'
                        : 'Keep on this device',
                () => here ? app.forgetOffline(track.id) : app.keepOffline([track]),
              );
            }),
          // Hear it now, without losing the queue. Missing until now: "play next" put
          // it after the current song, "play" on a record wrote over the queue, and
          // the thing most often wanted from a song's menu was neither.
          if (track.isReady || queuePosition != null)
            _item(
                sheet,
                Icons.play_arrow,
                'Play now',
                queuePosition == null
                    ? () => app.playTrackNow(track)
                    : () => app.player
                        ?.playTrack(track.id, indexHint: queuePosition)),
          _item(
              sheet,
              Icons.playlist_play,
              'Play next',
              queuePosition == null
                  ? () => app.addTrack(track, mode: 'next')
                  : () => app.playNextFromQueue(queuePosition)),
          if (queuePosition == null)
            _item(sheet, Icons.playlist_add, 'Add to queue', () => app.addTrack(track)),
          _item(sheet, Icons.library_add, 'Add to playlist…',
              () => addToPlaylistSheet(context, app, track), close: false),
          // Everything that belongs next to this one, as a queue of its own.
          _item(sheet, Icons.radio, 'Start a station',
              () => startStation(context, seed: track)),
          if (track.albumLine != null)
            _item(sheet, Icons.album_outlined, 'Go to ${track.albumLine}', () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AlbumPage(
                  album: AlbumSummary(
                    name: track.album!,
                    artist: track.artists.isEmpty ? '' : track.artists.first,
                    tracks: 0,
                  ),
                ),
              ));
            }),
          if (track.artists.isNotEmpty)
            _item(sheet, Icons.person_outline, 'Go to ${track.artists.first}', () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ArtistPage(
                  artist: ArtistSummary(name: track.artists.first, tracks: 0),
                ),
              ));
            }),
          _item(sheet, Icons.lyrics_outlined, 'Lyrics',
              () => showLyrics(context, track)),
          _item(sheet, Icons.edit_outlined, 'Edit details…', () async {
            final changed = await editTrackDialog(context, track);
            if (changed) onChanged?.call();
          }),
          if (track.isNotFetched)
            _item(sheet, Icons.cloud_download_outlined, 'Download now',
                () => _start(context, app, track)),
          if (track.state == 'failed')
            _item(sheet, Icons.refresh, 'Try downloading again',
                () => _start(context, app, track)),
          if (onRemove != null)
            _item(sheet, Icons.delete_outline, 'Remove', onRemove),
        ],
      ),
    ),
  );
}

/// Put a song in the queue, and say so — with a way to hear it straight away.
///
/// A tap that adds to the end of a queue on another tab changes nothing anybody can
/// see, so it got tapped again, and the queue filled with copies. Said here once, for
/// every list that adds on a tap or a swipe — including when the song was already
/// there, which is allowed and worth knowing.
Future<void> addAndSay(BuildContext context, Track track,
    {String mode = 'end'}) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final already = app.player?.items.any((t) => t.id == track.id) ?? false;
  try {
    await app.addTrack(track, mode: mode);
  } catch (e) {
    messenger.showSnackBar(problem(e));
    return;
  }
  final where = app.activeQueue?.name ?? 'the queue';
  final title = track.displayTitle;
  messenger.showSnackBar(snack(
    Text(mode == 'next'
        ? already
            ? 'Another copy of $title plays next'
            : '$title plays next'
        : already
            ? 'Added $title to "$where" again'
            : 'Added to "$where"'),
    // A guest's transport belongs to the room; what they can do is put it on.
    action: track.isReady && !app.jamControlsTheRoom
        ? SnackBarAction(
            label: 'Play', onPressed: () => app.playAdded(track, mode: mode))
        : null,
  ));
}

/// Ask for a song, and say what happened.
///
/// A download that cannot be started looks exactly like one that has been — the sheet
/// closes and nothing changes — so it says so. "Nowhere left to fetch it from" is the
/// real answer when every source a track has is gone, and it is a great deal more use
/// than a button that quietly does nothing.
Future<void> _start(BuildContext context, AppState app, Track track) async {
  final messenger = ScaffoldMessenger.of(context);
  final started = await app.fetchNow(track);
  messenger.showSnackBar(snack(Text(started
          ? '${track.displayTitle} is downloading'
          : 'Nowhere left to fetch ${track.displayTitle} from')));
}

Widget _item(BuildContext sheet, IconData icon, String label, VoidCallback action,
        {bool close = true}) =>
    ListTile(
      leading: Icon(icon),
      title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () {
        if (close) Navigator.of(sheet).pop();
        action();
      },
    );

class _Header extends StatelessWidget {
  const _Header({required this.track});
  final Track track;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(track.displayTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium),
            Text(
              [track.artistLine, if (track.albumLine != null) track.albumLine!]
                  .join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            // The one place the coloured dots in the lists are named, so the mark is
            // learnable rather than decorative.
            SourceChip(track: track),
          ],
        ),
      );
}

/// Correcting what a provider got wrong. The server has accepted these edits since the
/// upload work; there has simply never been a way to make one.
Future<bool> editTrackDialog(BuildContext context, Track track) async {
  final app = context.read<AppState>();
  final title = TextEditingController(text: track.title);
  final artists = TextEditingController(text: track.artists.join(', '));
  final album = TextEditingController(text: track.album ?? '');

  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Edit details'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: artists,
              decoration: const InputDecoration(
                labelText: 'Artists',
                helperText: 'Separated by commas',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: album,
              decoration: const InputDecoration(labelText: 'Album'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
      ],
    ),
  );

  if (saved != true) return false;
  await app.api.updateTrack(track.id, {
    'title': title.text.trim(),
    'artists': [
      for (final a in artists.text.split(',')) if (a.trim().isNotEmpty) a.trim()
    ],
    'album': album.text.trim().isEmpty ? null : album.text.trim(),
  });
  return true;
}
