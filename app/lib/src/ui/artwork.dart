import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/art_cache.dart';
import 'motion.dart';
import 'sleeve_art.dart';

/// Album art with a placeholder that is deliberately not a grey box: a track with no
/// cover yet should still look like part of the app rather than a hole in it.
class Artwork extends StatelessWidget {
  const Artwork({
    super.key,
    this.track,
    this.url,
    this.size = 44,
    this.radius = 6,
    this.small = true,
    this.sleeve = false,
    this.title,
  });

  final Track? track;

  /// What the song is called, where there is no [track]: the printed sleeve drawn
  /// when there is no picture is the song's own, not one shared by every song found
  /// elsewhere without one.
  final String? title;
  /// Render the cover as a physical record rather than a flat square. The picture
  /// arrives with its own shadow and transparent corners, so it is not clipped.
  final bool sleeve;
  /// For results that are not in the library yet and so have no track to ask.
  final String? url;
  final double size;
  final double radius;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final api = context.read<AppState>().api;
    final url = this.url ??
        (track == null
            ? null
            : sleeve
                ? api.sleeveUrl(track!, small: small)
                : api.coverUrl(track!, small: small));

    if (sleeve && url != null) {
      return SizedBox(
        width: size,
        height: size,
        child: Image(
            image: artwork(url, drawnAt: size, ratio: MediaQuery.devicePixelRatioOf(context)),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => Artwork(
                track: track, size: size, radius: radius, small: small),
            frameBuilder: (context, child, frame, wasSync) =>
                wasSync || frame != null
                    ? child
                    : Artwork(track: track, size: size, radius: radius, small: small)),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: url == null
            ? _missing()
            : Image(
                image: artwork(url,
                    drawnAt: size,
                    ratio: MediaQuery.devicePixelRatioOf(context)),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => _missing(),
                // A cover that has come off the network arrives into the placeholder
                // rather than replacing it between one frame and the next. Only one
                // that had to be waited for: an image already decoded is handed over
                // whole, and fading in something that was never missing is a list
                // that shimmers every time it scrolls.
                frameBuilder: (context, child, frame, wasSync) {
                  if (wasSync) return child;
                  return AnimatedSwitcher(
                    duration: Motion.base,
                    switchInCurve: Motion.enter,
                    child: frame == null
                        ? _loading(scheme)
                        : KeyedSubtree(key: const ValueKey('art'), child: child),
                  );
                },
              ),
      ),
    );
  }

  /// A song with no cover gets a sleeve printed for it. See PrintedSleeve: the same
  /// song gets the same one every time, and no two songs in a list look alike.
  Widget _missing() => PrintedSleeve(
        seed: track?.id ?? PrintedSleeve.seedOf(url ?? title),
        title: track?.displayTitle ?? title ?? '',
        size: size,
      );

  /// A cover on its way: plain paper, the colour of the page a shade deeper.
  ///
  /// Not the printed sleeve. That is for a song with no cover at all, and loud on
  /// purpose; shown while a real cover is loading, every list would flash a row of
  /// posters and then swap them all for the real thing.
  Widget _loading(ColorScheme scheme) =>
      ColoredBox(color: scheme.surfaceContainerHighest);
}

/// The picture for a song that may not be here: its own cover where the library has
/// one, else the picture where it was found (YouTube's, SoundCloud's, Spotify's —
/// fetched through the house), else a sleeve printed for it. The same everywhere a
/// song from elsewhere is shown: the search page and the booth's crate.
class ElsewhereArt extends StatelessWidget {
  const ElsewhereArt({
    super.key,
    this.track,
    this.cover,
    required this.title,
    this.by = '',
    this.size = 40,
    this.radius = 5,
  });

  final Track? track;

  /// The picture's path at the house, as a search answers with it.
  final String? cover;
  final String title, by;
  final double size, radius;

  @override
  Widget build(BuildContext context) {
    final t = track;
    if (t != null && t.hasCover) return Artwork(track: t, size: size, radius: radius);
    final c = cover;
    final url = c == null
        ? null
        : context.read<AppState>().api.remoteCoverUrl(c.contains('?') ? c : '$c?size=sm');
    return Artwork(url: url, title: title, size: size, radius: radius);
  }
}

/// A playlist's own cover: bands of the records in it, built by the server.
///
/// Separate from [Artwork] because the fallback is different — a playlist without art
/// yet still has a picture waiting to be generated, so the placeholder is the shape of
/// the cover rather than a music note.
class PlaylistArt extends StatelessWidget {
  const PlaylistArt({
    super.key,
    required this.playlist,
    this.size = 44,
    this.radius = 6,
    this.small = true,
  });

  final Playlist playlist;
  final double size;
  final double radius;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = context.read<AppState>().api.playlistCoverUrl(playlist, small: small);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: url == null
            ? _fallback(scheme)
            : Image(
                image: artwork(url,
                    drawnAt: size,
                    ratio: MediaQuery.devicePixelRatioOf(context)),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => _fallback(scheme),
                frameBuilder: (context, child, frame, wasSync) =>
                    wasSync || frame != null ? child : _fallback(scheme),
              ),
      ),
    );
  }

  Widget _fallback(ColorScheme scheme) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.primaryContainer, scheme.surfaceContainerHighest],
          ),
        ),
        child: Icon(playlist.isMirror ? Icons.cloud_outlined : Icons.playlist_play,
            size: size * 0.42, color: scheme.onSurfaceVariant),
      );
}

/// A song's picture from what stats and history rows carry: a cover path when there is
/// one, and the song's printed sleeve when there is not.
class CoverByPath extends StatelessWidget {
  const CoverByPath({
    super.key,
    required this.id,
    required this.title,
    required this.coverPath,
    required this.size,
  });

  final int id;
  final String title;
  final String? coverPath;
  final double size;

  @override
  Widget build(BuildContext context) {
    final api = context.read<AppState>().api;
    final url = api.coverUrlForPath(coverPath, small: size < 120);
    if (url == null) return PrintedSleeve(seed: id, title: title, size: size);
    return SizedBox.square(
      dimension: size,
      child: Image(
        image: artwork(url, drawnAt: size, ratio: MediaQuery.devicePixelRatioOf(context)),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => PrintedSleeve(seed: id, title: title, size: size),
      ),
    );
  }
}
