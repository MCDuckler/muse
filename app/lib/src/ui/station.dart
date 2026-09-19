import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'snack.dart';

/// Put something on, and keep playing what belongs next to it.
///
/// One way in from everywhere it makes sense to start one — a song's menu, a record,
/// an artist, the queue — so that "station" means the same thing wherever it is asked
/// for: a queue of its own, named after what it came from, which is topped up as it
/// runs down and can be saved to the library like any other.
Future<void> startStation(
  BuildContext context, {
  Track? seed,
  String? album,
  String? artist,
}) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final kind = album != null
      ? 'album'
      : artist != null && seed == null
          ? 'artist'
          : 'track';
  if (kind == 'track' && seed == null) {
    messenger.say(snack(const Text('Nothing playing to start a station from')));
    return;
  }

  messenger.say(snack(const Text('Starting a station…')));
  try {
    await app.startStation(
        kind: kind, seed: seed, album: album, artist: artist);
    messenger.say(snack(Text(app.activeQueue?.name ?? 'Station')));
  } catch (e) {
    messenger.say(snack(Text('$e')));
  }
}

/// A station is a queue, so saving one is saving a queue — under its own name, which
/// is what makes it look like a record somebody kept rather than a queue they left.
Future<void> keepStation(BuildContext context) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final queue = app.activeQueue;
  if (queue == null) return;
  try {
    await app.api.saveQueueAsPlaylist(queue.id, name: queue.name);
    await app.refreshPlaylists();
    messenger.say(snack(Text('"${queue.name}" is in your library')));
  } catch (e) {
    messenger.say(snack(Text('$e')));
  }
}
