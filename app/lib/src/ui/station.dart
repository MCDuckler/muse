import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'dialogs.dart';
import 'library_page.dart' show PlaylistPage;
import 'pane.dart';
import 'snack.dart';

/// Point at something and get a station: a playlist the machine writes of what
/// belongs next to it, and keeps writing.
///
/// One way in from everywhere it makes sense to start one — a song's menu, a record,
/// an artist, a genre, the queue — so that "station" means the same thing wherever it
/// is asked for: a playlist of thirty songs, named after what it came from, filed with
/// the rest, to look through and put on from anywhere. Its page opens either way.
///
/// With [play] it is put on as well, from the top, as a queue of its own that is
/// topped up from the station as it is listened through. Without, what is playing
/// carries on and the station waits on its page.
Future<void> startStation(
  BuildContext context, {
  Track? seed,
  String? album,
  String? artist,
  String? genre,
  bool play = true,
}) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final kind = genre != null
      ? 'genre'
      : album != null
          ? 'album'
          : artist != null && seed == null
              ? 'artist'
              : 'track';
  if (kind == 'track' && seed == null) {
    messenger.say(snack(const Text('Nothing playing to start a station from')));
    return;
  }

  // A genre's station has to find its first songs out in the world, which takes a
  // few seconds the first time; the message says so rather than looking stuck.
  messenger.say(snack(Text(genre != null
      ? 'Finding what the world plays as $genre…'
      : 'Writing a station…')));
  try {
    final made = await app.startStation(
        kind: kind, seed: seed, album: album, artist: artist, genre: genre, play: play);
    messenger.say(snack(Text(play
        ? '"${made.name}" is on — ${made.itemCount} songs'
        : '"${made.name}" is in your library — ${made.itemCount} songs')));
    if (context.mounted) {
      await openPage(context, (_) => PlaylistPage(playlistId: made.id, name: made.name));
    }
  } catch (e) {
    messenger.say(problem(e));
  }
}

/// A station kept as a playlist of your own: a copy, under a name of your choosing,
/// that the machine will not write over. The station itself stays as it is.
Future<void> keepStation(BuildContext context, {Playlist? station}) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final id = station?.id ?? app.activeQueue?.stationPlaylistId;
  final name = station?.name ?? app.activeQueue?.name;
  if (id == null || name == null) {
    messenger.say(snack(const Text('This is not a station')));
    return;
  }
  final chosen = await promptForName(context, 'Keep as a playlist',
      name.endsWith(' radio') ? name.substring(0, name.length - 6) : name);
  if (chosen == null) return;
  try {
    await app.api.clonePlaylist(id, name: chosen);
    await app.refreshPlaylists();
    messenger.say(snack(Text('"$chosen" is in your library')));
  } catch (e) {
    messenger.say(problem(e));
  }
}
