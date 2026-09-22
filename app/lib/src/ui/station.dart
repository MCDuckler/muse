import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'queue_page.dart' show QueueScreen;
import 'snack.dart';

/// Put something on, and keep playing what belongs next to it.
///
/// One way in from everywhere it makes sense to start one — a song's menu, a record,
/// an artist, the queue — so that "station" means the same thing wherever it is asked
/// for: a queue of its own, named after what it came from, which is topped up as it
/// runs down and can be saved to the library like any other.
///
/// With [play] off it is only made: what is playing carries on, the station sits
/// beside it as a queue of its own, and the message offers the way in. Nothing
/// playing, and it is opened straight away, parked on its first song.
Future<void> startStation(
  BuildContext context, {
  Track? seed,
  String? album,
  String? artist,
  bool play = true,
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

  messenger.say(snack(Text(play ? 'Starting a station…' : 'Making a station…')));
  try {
    final made = await app.startStation(
        kind: kind, seed: seed, album: album, artist: artist, play: play);
    if (play) {
      messenger.say(snack(Text(made.name)));
    } else if (app.activeQueue?.id == made.id) {
      messenger.say(snack(Text('"${made.name}" is on, waiting for play')));
      if (context.mounted) {
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const QueueScreen()));
      }
    } else {
      messenger.say(snack(
        Text('"${made.name}" is ready'),
        action: SnackBarAction(
            label: 'Open',
            onPressed: () => app.openQueue(made.id, autoplay: false)),
      ));
    }
  } catch (e) {
    messenger.say(problem(e));
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
