import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/player.dart';

/// One timed line of an LRC file.
class LyricLine {
  const LyricLine(this.at, this.text);
  final Duration at;
  final String text;
}

/// Parse LRC. Lines can carry several timestamps ("[00:12.00][01:04.00] chorus"), and
/// a file that is only mildly malformed should still show what it can rather than
/// nothing at all.
List<LyricLine> parseLrc(String source) {
  final stamp = RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]');
  final out = <LyricLine>[];
  for (final raw in source.split('\n')) {
    final matches = stamp.allMatches(raw).toList();
    if (matches.isEmpty) continue;
    final text = raw.substring(matches.last.end).trim();
    if (text.isEmpty) continue;               // a timestamp with no words is a marker
    for (final m in matches) {
      final fraction = m.group(3);
      final ms = fraction == null
          ? 0
          : int.parse(fraction.padRight(3, '0').substring(0, 3));
      out.add(LyricLine(
        Duration(
          minutes: int.parse(m.group(1)!),
          seconds: int.parse(m.group(2)!),
          milliseconds: ms,
        ),
        text,
      ));
    }
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out;
}

/// Which line is current at a given position: the last one that has started.
int currentLineIndex(List<LyricLine> lines, Duration position) {
  var index = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].at <= position) {
      index = i;
    } else {
      break;
    }
  }
  return index;
}

Future<void> showLyrics(BuildContext context, Track track) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _LyricsSheet(track: track),
  );
}

class _LyricsSheet extends StatefulWidget {
  const _LyricsSheet({required this.track});
  final Track track;

  @override
  State<_LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends State<_LyricsSheet> {
  Future<({String? synced, String? plain, String? source})>? _future;
  final _scroll = ScrollController();
  int _lastLine = -1;

  @override
  void initState() {
    super.initState();
    _future = context.read<AppState>().api.lyrics(widget.track.id);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _follow(int index, int total) {
    if (index < 0 || index == _lastLine || !_scroll.hasClients) return;
    _lastLine = index;
    const lineHeight = 38.0;
    final target = (index * lineHeight - 140)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(target,
        duration: const Duration(milliseconds: 420), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<AppState>().player;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.track.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium),
                Text(widget.track.artistLine,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<({String? synced, String? plain, String? source})>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return _Message(
                    icon: Icons.cloud_off,
                    title: 'Could not fetch lyrics',
                    body: 'The lyrics service is rate limited; try again in a minute.',
                  );
                }
                final data = snap.data!;
                final synced = data.synced;
                if (synced != null && synced.trim().isNotEmpty) {
                  final lines = parseLrc(synced);
                  if (lines.isNotEmpty) {
                    return _Synced(
                      lines: lines,
                      player: player,
                      scroll: controller,
                      onLine: (i) => _follow(i, lines.length),
                    );
                  }
                }
                final plain = data.plain;
                if (plain != null && plain.trim().isNotEmpty) {
                  return ListView(
                    controller: controller,
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                    children: [
                      Text(plain,
                          style: Theme.of(context)
                              .textTheme
                              .bodyLarge
                              ?.copyWith(height: 1.7)),
                    ],
                  );
                }
                return const _Message(
                  icon: Icons.lyrics_outlined,
                  title: 'No lyrics for this one',
                  body: 'Nothing was found for this title and artist.',
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Synced extends StatelessWidget {
  const _Synced({
    required this.lines,
    required this.player,
    required this.scroll,
    required this.onLine,
  });

  final List<LyricLine> lines;
  final PlayerService? player;
  final ScrollController scroll;
  final void Function(int index) onLine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<PlayerSnapshot>(
      stream: player?.snapshots,
      initialData: player?.last,
      builder: (context, snap) {
        final position = snap.data?.position ?? Duration.zero;
        final active = currentLineIndex(lines, position);
        WidgetsBinding.instance.addPostFrameCallback((_) => onLine(active));

        return ListView.builder(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 60),
          itemCount: lines.length,
          itemBuilder: (context, i) {
            final isNow = i == active;
            return GestureDetector(
              // Through the app, like the scrubber: in a jam a seek is the room's.
              onTap: () => context.read<AppState>().seekTo(lines[i].at),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Text(
                  lines[i].text,
                  style: TextStyle(
                    fontSize: isNow ? 19 : 16.5,
                    height: 1.3,
                    fontWeight: isNow ? FontWeight.w700 : FontWeight.w400,
                    color: isNow ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.body});
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
