import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/booth/booth.dart';
import '../state/booth/deck.dart';
import 'artwork.dart';
import 'feel.dart';
import 'mag.dart';
import 'mag_parts.dart';
import 'snack.dart';
import 'song_row.dart';

/// The booth, early: the engine with a plain face on it.
///
/// Two decks, the fader, the kills, sync and a transition — enough to hear whether
/// the mixing works on a real phone, which is what this slice is for. The room it
/// will live in — the records, the printed waveforms, the crate — comes after the
/// engine has proved itself.
class BoothPage extends StatefulWidget {
  const BoothPage({super.key});

  @override
  State<BoothPage> createState() => _BoothPageState();
}

class _BoothPageState extends State<BoothPage> {
  Timer? _tick;
  Transition _kind = Transition.blend;
  int _bars = 16;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    unawaited(app.booth.init());
    // The booth makes the sound now; the ordinary player keeps quiet.
    unawaited(app.player?.pause());
    // The clocks on the decks move between the engine's reports; redrawn ten times a
    // second, which is enough for a number and a beat light.
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final booth = app.booth;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: booth,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('The booth')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 40),
          children: [
            _DeckCard(booth: booth, deck: booth.a),
            const SizedBox(height: 10),
            _mixer(context, booth, scheme),
            const SizedBox(height: 10),
            _DeckCard(booth: booth, deck: booth.b),
            const SizedBox(height: 16),
            Text(
              [
                'Mixer: ${booth.mixer.runtimeType}',
                booth.mixer.canKill ? 'kills' : 'no kills on this device',
                booth.mixer.canFilter ? 'filter' : 'no filter',
              ].join(' · '),
              style: Mag.typewriter(11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mixer(BuildContext context, Booth booth, ColorScheme scheme) {
    final master = booth.master;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          children: [
            Row(
              children: [
                Text('A', style: Mag.numerals(18, color: scheme.onSurface)),
                Expanded(
                  child: Slider(
                    value: booth.crossfader,
                    onChanged: (v) => booth.setCrossfader(v),
                  ),
                ),
                Text('B', style: Mag.numerals(18, color: scheme.onSurface)),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('MASTER ${master.name}', style: Mag.flag(10, color: scheme.primary)),
                DropdownButton<Transition>(
                  value: _kind,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final k in Transition.values)
                      DropdownMenuItem(value: k, child: Text(k.name)),
                  ],
                  onChanged: (k) => setState(() => _kind = k ?? _kind),
                ),
                DropdownButton<int>(
                  value: _bars,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final n in const [4, 8, 16, 32])
                      DropdownMenuItem(value: n, child: Text('$n bars')),
                  ],
                  onChanged: (n) => setState(() => _bars = n ?? _bars),
                ),
                PressButton(
                  label: booth.inTransition ? 'Stop' : 'Go',
                  loud: !booth.inTransition,
                  onTap: booth.other(master).loaded
                      ? () {
                          feel(Feel.commit);
                          if (booth.inTransition) {
                            booth.stopTransition();
                          } else {
                            unawaited(booth.go(_kind, bars: _bars));
                          }
                        }
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DeckCard extends StatelessWidget {
  const _DeckCard({required this.booth, required this.deck});
  final Booth booth;
  final Deck deck;

  Future<void> _pick(BuildContext context) async {
    final app = context.read<AppState>();
    final items = app.player?.items ?? const <Track>[];
    final ready = [for (final t in items) if (t.isReady) t];
    if (ready.isEmpty) {
      ScaffoldMessenger.of(context).say(snack(const Text('Nothing in the queue to put on')));
      return;
    }
    final picked = await showModalBottomSheet<Track>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final t in ready.take(60))
              SongRow(
                track: t,
                showMenu: false,
                swipeToPlayNext: false,
                plays: false,
                onTap: () => Navigator.of(sheet).pop(t),
              ),
          ],
        ),
      ),
    );
    if (picked != null && context.mounted) await booth.load(deck, picked);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final now = DateTime.now();
    final beat = deck.beatAt(now);
    final onBeat = beat != null && beat.phase < 0.15;
    final isMaster = identical(booth.master, deck);
    final kills = booth.kills[deck] ?? (low: false, mid: false, high: false);
    final t = deck.track;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(
            color: isMaster ? scheme.primary : scheme.onSurface.withValues(alpha: 0.2),
            width: isMaster ? 1.5 : 1),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(deck.name, style: Mag.numerals(26, color: scheme.onSurface)),
                const SizedBox(width: 12),
                if (t != null) Artwork(track: t, size: 40, radius: 4),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t?.displayTitle ?? 'Nothing on',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
                      Text(
                        [
                          if (t != null) t.artistLine,
                          if (deck.bpm != null) '${deck.bpm!.toStringAsFixed(1)} bpm',
                          if (deck.tempo != 1.0) '${((deck.tempo - 1) * 100).toStringAsFixed(1)}%',
                          if (t != null && !deck.hasBeats) 'no grid',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                // The beat light: on the one it is the accent.
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: onBeat
                        ? (beat.index - (deck.timing?.barStartsOn ?? 0)) % 4 == 0
                            ? scheme.primary
                            : scheme.onSurface
                        : scheme.onSurface.withValues(alpha: 0.12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${SongRow.formatDuration(deck.position)} / ${SongRow.formatDuration(deck.duration)}',
              style: Mag.typewriter(12, color: scheme.onSurfaceVariant),
            ),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: deck.tempo,
                    min: 0.92,
                    max: 1.08,
                    onChanged: t == null ? null : (v) => deck.setTempo(v),
                  ),
                ),
                TextButton(
                  onPressed: t == null ? null : () => deck.setTempo(1.0),
                  child: const Text('0%'),
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                PressButton(label: t == null ? 'Load' : 'Change', onTap: () => _pick(context)),
                PressButton(
                  label: deck.playing ? 'Pause' : 'Play',
                  loud: !deck.playing && t != null,
                  onTap: t == null ? null : () => deck.playing ? deck.pause() : deck.play(),
                ),
                PressButton(
                  label: 'On the one',
                  onTap: t == null || deck.playing ? null : () => booth.startOnBeat(deck),
                ),
                PressButton(
                  label: 'Sync',
                  onTap: t == null
                      ? null
                      : () async {
                          final ok = await booth.sync(deck);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).say(snack(Text(ok
                              ? 'Synced to ${booth.other(deck).name}'
                              : 'Too far apart to sync, or no grid')));
                        },
                ),
                PressButton(label: 'Align', onTap: t == null ? null : () => booth.align(deck)),
                PressButton(
                  label: deck.loopStart == null ? 'Loop 4' : 'Unloop',
                  onTap: t == null ? null : () => deck.loopStart == null ? deck.loop(4) : deck.unloop(),
                ),
                for (final (label, on, set) in [
                  ('LOW', kills.low, (bool v) => booth.setKills(deck, low: v, mid: kills.mid, high: kills.high)),
                  ('MID', kills.mid, (bool v) => booth.setKills(deck, low: kills.low, mid: v, high: kills.high)),
                  ('HIGH', kills.high, (bool v) => booth.setKills(deck, low: kills.low, mid: kills.mid, high: v)),
                ])
                  PressButton(
                    label: on ? '$label ✕' : label,
                    loud: on,
                    onTap: booth.mixer.canKill ? () => set(!on) : null,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
