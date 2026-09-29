import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../worker/this_computer.dart' show fetchHereNow;
import 'mag.dart';
import 'mag_parts.dart';
import 'snack.dart';
import 'song_row.dart';

/// Bring a pick into the catalog as a track that will play: a song from YouTube Music
/// is resolved (fetched, on this computer, at once), one of yours that was never
/// fetched is fetched. Answers with the track.
Future<Track> bringIn(AppState app, Pick p) async {
  final t = p.track ?? await app.api.resolve(videoId: p.hit!.videoId);
  if (!t.isReady) unawaited(fetchHereNow([t.id]));
  return t;
}

/// How far to reach past the library: three stops rather than a slider, because the
/// three answers are what anybody means — what I have, a bit of both, something new.
class FreshDial extends StatelessWidget {
  const FreshDial({super.key, required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  static const stops = [(0.0, 'YOURS'), (0.5, 'MIXED'), (1.0, 'NEW')];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final (v, label) in stops)
        Semantics(
          button: true,
          selected: (value - v).abs() < 0.01,
          child: InkWell(
            onTap: () => onChanged(v),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Text(label,
                  style: Mag.typewriter(10.5,
                          color: (value - v).abs() < 0.01 ? scheme.primary : scheme.onSurfaceVariant,
                          bold: (value - v).abs() < 0.01)
                      .copyWith(
                          decoration: (value - v).abs() < 0.01 ? TextDecoration.underline : null,
                          decorationColor: scheme.primary)),
            ),
          ),
        ),
    ]);
  }
}

/// A small word for where a pick is, when that changes what a tap does.
class WhereTag extends StatelessWidget {
  const WhereTag(this.pick, {super.key});
  final Pick pick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, tip) = switch (pick.where) {
      'new' => ('NEW', 'Not here yet — fetched when you add it'),
      'house' => ('HOUSE', 'Somebody here already has it — it plays at once'),
      'waiting' => ('YOURS', 'In your library, never fetched'),
      _ => (null, null),
    };
    if (label == null) return const SizedBox.shrink();
    return Tooltip(
      message: tip!,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.primary.withValues(alpha: 0.55)),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(label, style: Mag.typewriter(9, color: scheme.primary, bold: true)),
      ),
    );
  }
}

/// A list of picks under a head: what goes with this list, with the queue, with you.
///
/// Every place that offers songs used to draw its own list and answer its own way;
/// this is the one. [ask] is called with the dial's reach and how many times MORE has
/// been pressed. A row says why it is offered and where the song is; a tap plays what
/// is here and brings in what is not, [onAdd] is the row's one action (add to this
/// playlist, to the queue), and the cross waves a song away for good. Nothing is shown
/// when there is nothing to offer.
class PicksSection extends StatefulWidget {
  const PicksSection({
    super.key,
    required this.title,
    required this.ask,
    this.blurb,
    this.onAdd,
    this.addIcon = Icons.add_circle_outline,
    this.addTooltip = 'Add',
    this.dial = true,
    this.fresh = 0.5,
    this.refreshKey,
    this.padding = const EdgeInsets.fromLTRB(8, 28, 8, 2),
  });

  final String title;
  final String? blurb;
  final Future<List<Pick>> Function(double fresh, int round) ask;
  final Future<void> Function(Pick pick, Track track)? onAdd;
  final IconData addIcon;
  final String addTooltip;
  final bool dial;
  final double fresh;

  /// When this changes, ask again — a playlist that grew wants different songs.
  final Object? refreshKey;
  final EdgeInsets padding;

  @override
  State<PicksSection> createState() => _PicksSectionState();
}

class _PicksSectionState extends State<PicksSection> {
  List<Pick>? _picks;
  final _busy = <String>{};
  bool _asking = false;
  int _round = 0;
  late double _fresh = widget.fresh;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  @override
  void didUpdateWidget(PicksSection old) {
    super.didUpdateWidget(old);
    if (old.refreshKey != widget.refreshKey) _ask();
  }

  Future<void> _ask() async {
    setState(() => _asking = true);
    try {
      final got = await widget.ask(_fresh, _round);
      if (mounted) setState(() => _picks = got);
    } catch (_) {
      // A server from before this, or no connection: the page is still the page.
      if (mounted) setState(() => _picks ??= const []);
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  void _drop(Pick p) =>
      setState(() => _picks = [for (final o in _picks ?? const <Pick>[]) if (o.key != p.key) o]);

  Future<void> _add(Pick p) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final before = _picks;
    // Off the list at once: it is in, and the page behind it catches up after.
    _drop(p);
    try {
      final t = await bringIn(app, p);
      await widget.onAdd!(p, t);
    } catch (e) {
      if (mounted) setState(() => _picks = before);
      messenger.say(problem(e));
    }
  }

  Future<void> _play(Pick p) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy.add(p.key));
    try {
      final t = await bringIn(app, p);
      await app.playTrackNow(t);
      if (!p.isHere) messenger.say(snack(Text('${t.displayTitle} — fetching it, it plays when it is here')));
    } catch (e) {
      messenger.say(problem(e));
    } finally {
      if (mounted) setState(() => _busy.remove(p.key));
    }
  }

  Future<void> _dismiss(Pick p) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    _drop(p);
    try {
      await app.api.dismissPick(p);
      messenger.say(snack(Text('Not offered again: ${p.row.displayTitle}')));
    } catch (e) {
      messenger.say(problem(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final picks = _picks;
    // Nothing to offer, and not about to have: no head over an empty space. The dial
    // stays if it was turned — "nothing new" is an answer, and the way back is on it.
    if (picks != null && picks.isEmpty && !_asking && (_fresh - widget.fresh).abs() < 0.01) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: widget.padding,
          child: Row(children: [
            Expanded(child: SectionFlag(widget.title)),
            if (widget.dial)
              FreshDial(
                  value: _fresh,
                  onChanged: (v) {
                    setState(() {
                      _fresh = v;
                      _round = 0;
                    });
                    _ask();
                  }),
            IconButton(
              tooltip: 'Something else',
              visualDensity: VisualDensity.compact,
              onPressed: _asking
                  ? null
                  : () {
                      _round++;
                      _ask();
                    },
              icon: _asking
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 18),
            ),
          ]),
        ),
        if (widget.blurb != null)
          Padding(
            padding: EdgeInsets.fromLTRB(widget.padding.left, 0, widget.padding.right, 6),
            child: Text(widget.blurb!, style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
          ),
        if (picks == null)
          const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))))
        else if (picks.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_fresh >= 0.99 ? 'Nothing new beside these just now.' : 'Nothing of yours goes with these yet.',
                textAlign: TextAlign.center, style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
          )
        else
          for (final p in picks) _row(p, scheme),
      ],
    );
  }

  Widget _row(Pick p, ColorScheme scheme) {
    final busy = _busy.contains(p.key);
    return Column(
      key: ValueKey('pick-${p.key}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SongRow(
          track: p.row,
          showDuration: false,
          showMenu: p.track != null,
          swipeToPlayNext: p.track != null,
          plays: p.isHere,
          onTap: busy ? null : () => _play(p),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            WhereTag(p),
            if (busy)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (widget.onAdd != null)
              IconButton(
                icon: Icon(p.isHere || p.where == 'waiting' ? widget.addIcon : Icons.download_outlined),
                tooltip: p.isHere || p.where == 'waiting' ? widget.addTooltip : '${widget.addTooltip} — fetched first',
                onPressed: () => _add(p),
              ),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              visualDensity: VisualDensity.compact,
              tooltip: 'Not for me',
              onPressed: busy ? null : () => _dismiss(p),
            ),
          ]),
        ),
        if (p.why.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(66, 0, 12, 6),
            child: Text(p.why,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Mag.typewriter(10, color: scheme.onSurfaceVariant.withValues(alpha: 0.8))),
          ),
      ],
    );
  }
}
