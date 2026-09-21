import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'dialogs.dart';
import 'selection_bar.dart';
import 'song_row.dart';

/// One way of rendering a list of tracks, used by every browse screen.
///
/// It carries the actions that were previously scattered or missing: play the whole
/// list from here, shuffle it, queue a single track, or put one in a playlist.
/// Finding one song in a list that is longer than a screen.
///
/// A playlist of four hundred and a queue of nine thousand could only be scrolled.
/// The library's own lists have been searchable for a while; the lists *inside* it
/// were not, which is where somebody is standing when they think "where is that song".
///
/// Filtered here rather than asked of the server: these lists are already in the app's
/// hands, and a round trip to narrow forty rows is a round trip nobody needs.
class _Filter extends StatefulWidget {
  const _Filter({required this.onChanged});
  final ValueChanged<String> onChanged;

  @override
  State<_Filter> createState() => _FilterState();
}

class _FilterState extends State<_Filter> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
        child: SizedBox(
          height: 40,
          child: TextField(
            controller: _text,
            onChanged: (v) => setState(() => widget.onChanged(v)),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              hintText: 'Find in this list',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _text.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      tooltip: 'Clear',
                      onPressed: () {
                        _text.clear();
                        setState(() => widget.onChanged(''));
                      },
                    ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
      );
}

class TrackList extends StatefulWidget {
  const TrackList({
    super.key,
    required this.tracks,
    this.header,
    this.onRemove,
    this.named,
    this.selectable,
    this.onEndReached,
    this.loadingMore = false,
    this.searchable = true,
  });

  /// Whether this list offers a way to find one song in it. On by default, and off
  /// where the list is short by construction — the songs on one record.
  final bool searchable;

  /// Called as the bottom comes into view, for a list that arrives a page at a time.
  final VoidCallback? onEndReached;
  final bool loadingMore;

  /// What to call this list when several songs are picked out of it — "playlist:3",
  /// "album:Low". Lists that pass nothing cannot be selected in.
  final String? selectable;

  final List<Track> tracks;
  final String? header;
  final void Function(int index)? onRemove;

  /// The name of the thing being listed — an album, a playlist. Given one, playing it
  /// makes a queue of its own instead of writing over whatever you were listening to.
  final String? named;

  @override
  State<TrackList> createState() => _TrackListState();
}

class _TrackListState extends State<TrackList> {
  String _looking = '';

  /// What a song has to match: its title, whoever made it, or the record it is on.
  bool _matches(Track t, String q) =>
      t.displayTitle.toLowerCase().contains(q) ||
      t.artistLine.toLowerCase().contains(q) ||
      (t.albumLine ?? '').toLowerCase().contains(q);

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final q = _looking.trim().toLowerCase();
    // A search in a list of nine thousand is a search over what is in this app's
    // hands, which is the window the server sent.
    final tracks = q.isEmpty
        ? widget.tracks
        : [for (final t in widget.tracks) if (_matches(t, q)) t];
    final onRemove = widget.onRemove;
    final selectable = widget.selectable;
    final named = widget.named;
    final header = widget.header;
    final onEndReached = widget.onEndReached;
    final loadingMore = widget.loadingMore;

    if (widget.tracks.isEmpty) {
      return const EmptyHint(
        icon: Icons.music_note,
        title: 'Nothing here yet',
        body: 'Tracks appear once they are in your library.',
      );
    }

    return SelectionOver(
      bar: selectable == null
          ? const SizedBox.shrink()
          : SelectionBar(
            where: selectable,
            tracks: tracks,
            removeLabel: onRemove == null ? 'Remove' : 'Remove from this list',
            onRemove: onRemove == null
                ? null
                : (picked) async {
                    // Backwards through the positions, so removing one does not shift
                    // the next one out from under the index about to be used.
                    final at = [
                      for (var i = 0; i < tracks.length; i++)
                        if (picked.any((p) => p.id == tracks[i].id)) i
                    ];
                    for (final i in at.reversed) {
                      onRemove(i);
                    }
                  },
          ),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          // Well before the last row, so the next page is there by the time somebody
          // scrolls to where it goes.
          if (onEndReached != null && n.metrics.extentAfter < 900) onEndReached();
          return false;
        },
        child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 160),
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: tracks.length + (loadingMore ? 2 : 1),
            itemBuilder: (context, i) {
              if (i == 0) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Head(tracks: tracks, header: header, named: named),
                    // Only where there is enough to lose something in.
                    if (widget.searchable && widget.tracks.length >= 12)
                      _Filter(onChanged: (v) => setState(() => _looking = v)),
                    if (q.isNotEmpty && tracks.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text('Nothing here matches “$_looking”.',
                            style: Theme.of(context).textTheme.bodySmall),
                      ),
                  ],
                );
              }
              if (i - 1 >= tracks.length) return const _More();
              final t = tracks[i - 1];
              return SongRow(
                track: t,
                selectable: selectable,
                onTap: () => app.playNow(tracks, startAt: i - 1, named: named),
                onRemove: onRemove == null ? null : () => onRemove(i - 1),
              );
            },
        ),
      ),
    );
  }
}

/// The list is still arriving.
class _More extends StatelessWidget {
  const _More();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
              width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
}

class _Head extends StatelessWidget {
  const _Head({required this.tracks, this.header, this.named});
  final List<Track> tracks;
  final String? header;
  final String? named;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    void play() => app.playNow(tracks, named: named);
    void shuffle() => app.playNow(tracks, shuffle: true, named: named);
    // How big the words are, as a multiple of what they were designed at.
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      child: LayoutBuilder(builder: (context, box) {
        // Two labelled buttons need about two hundred and fifty points at the size
        // they were drawn at, and more as the type grows. A small phone with large
        // text had neither: the row ran forty points off the edge of the screen. Where
        // the words will not fit, the buttons keep their icons and say what they do
        // when held.
        final labelled = box.maxWidth >= 250 * scale;
        return Row(
          children: [
            Expanded(
              child: Text(header ?? '${tracks.length} tracks',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            if (labelled) ...[
              TextButton.icon(
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Play'),
                onPressed: play,
              ),
              const SizedBox(width: 4),
              TextButton.icon(
                icon: const Icon(Icons.shuffle, size: 18),
                label: const Text('Shuffle'),
                onPressed: shuffle,
              ),
            ] else ...[
              IconButton(
                icon: const Icon(Icons.play_arrow),
                tooltip: 'Play',
                onPressed: play,
              ),
              IconButton(
                icon: const Icon(Icons.shuffle),
                tooltip: 'Shuffle',
                onPressed: shuffle,
              ),
            ],
          ],
        );
      }),
    );
  }
}
