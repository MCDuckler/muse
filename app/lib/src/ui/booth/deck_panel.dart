import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../state/booth/booth.dart';
import '../../state/booth/deck.dart' as engine;
import '../feel.dart';
import '../mag.dart';
import '../mag_parts.dart';
import '../record_stage.dart' show Disc, RecordLight, Tonearm;
import '../snack.dart';
import '../stage/arm_grip.dart';
import 'booth_clock.dart';
import 'meters.dart';
import 'wave_strip.dart';

/// One deck: the record turning, the arm on it, and what is done to this record
/// alone.
///
/// The record is the app's own — the same pressing, the same light on it, the same
/// arm you can pick up — turning at the deck's tempo on the room's clock, so a record
/// pitched up visibly runs faster. On a phone the deck carries its own waveform and
/// its controls wrap; on a desk the waveforms are laid out together above the room
/// and the deck is a column, so its controls can be grouped and labelled rather than
/// a wall of identical boxes.
class DeckPanel extends StatefulWidget {
  const DeckPanel({
    super.key,
    required this.booth,
    required this.deck,
    required this.onLoad,
    this.wide = false,
    this.showWave = true,
    this.record = 196,
  });

  /// How big the record is drawn, on a desk: smaller where the wall is shorter.
  final double record;

  final Booth booth;
  final engine.Deck deck;
  final VoidCallback onLoad;

  /// A desk: the record big, the controls grouped, no waveform of its own.
  final bool wide;
  final bool showWave;

  @override
  State<DeckPanel> createState() => _DeckPanelState();
}

class _DeckPanelState extends State<DeckPanel> with SingleTickerProviderStateMixin {
  late final AnimationController _arm =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
  final _reading = ValueNotifier<ArmReading>(const ArmReading());
  ValueNotifier<Duration>? _position;

  @override
  void initState() {
    super.initState();
    widget.deck.addListener(_changed);
    _changed();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The room's clock, and the arm's reading taken from it.
    final now = BoothClock.of(context).positionOf(widget.deck);
    if (identical(now, _position)) return;
    _position?.removeListener(_moved);
    _position = now..addListener(_moved);
  }

  @override
  void dispose() {
    _position?.removeListener(_moved);
    widget.deck.removeListener(_changed);
    _arm.dispose();
    _reading.dispose();
    super.dispose();
  }

  void _moved() {
    final d = widget.deck;
    _reading.value =
        ArmReading(position: _position!.value, length: d.duration, playing: d.playing);
  }

  void _changed() {
    final d = widget.deck;
    if (d.playing) {
      _arm.forward();
    } else {
      _arm.reverse();
    }
    final t = d.track;
    if (t != null && !widget.booth.bands.containsKey(t.id)) {
      unawaited(widget.booth.fetchBands(t).then((_) {
        if (mounted) setState(() {});
      }));
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.booth;
    final d = widget.deck;
    final scheme = Theme.of(context).colorScheme;
    final t = d.track;
    final isMaster = identical(b.master, d);

    final body = widget.wide
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _facts(context, spread: true),
              const SizedBox(height: 10),
              Center(child: _record(context, widget.record)),
              const SizedBox(height: 12),
              _pitch(context),
              const SizedBox(height: 8),
              _transport(context),
              const SizedBox(height: 10),
              _cuesAndLoops(context),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _record(context, 112),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _facts(context),
                        const SizedBox(height: 2),
                        Text(t?.displayTitle ?? 'Nothing on',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Mag.title(15, color: scheme.onSurface)),
                        if (t != null)
                          Text(t.artistLine,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
                        if (widget.showWave) ...[
                          const SizedBox(height: 6),
                          WaveLane(
                              booth: b,
                              deck: d,
                              height: 56,
                              window: const Duration(seconds: 14)),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _pitch(context),
              const SizedBox(height: 6),
              _transport(context),
              const SizedBox(height: 8),
              _cuesAndLoops(context),
              const SizedBox(height: 8),
              _bands(context),
            ],
          );

    return Container(
      decoration: BoxDecoration(
        border: Border.all(
            color: isMaster ? scheme.primary : scheme.onSurface.withValues(alpha: 0.35),
            width: isMaster ? 1.5 : 1),
        borderRadius: BorderRadius.circular(3),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: body,
    );
  }

  // ------------------------------------------------------------------ the record
  Widget _record(BuildContext context, double side) {
    final app = context.read<AppState>();
    final d = widget.deck;
    final scheme = Theme.of(context).colorScheme;
    final t = d.track;
    final radius = side * 0.42;
    final spin = BoothClock.of(context).turnOf(d);
    final hand = t == null
        ? null
        : ArmHand(
            reading: _reading,
            onPlace: (at) async {
              await d.seek(at);
              if (!d.playing) await d.play();
            },
            onPark: d.pause,
          );
    return SizedBox(
      width: side,
      height: side,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          if (t != null)
            Disc.spinning(
              url: app.api.discUrl(t) ?? Disc.plain(t),
              spin: spin,
              size: radius * 2,
              roll: 0,
              fade: 1,
              label: app.discLabel,
            )
          else
            Container(
              width: radius * 2,
              height: radius * 2,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border:
                    Border.all(color: scheme.onSurface.withValues(alpha: 0.25), width: 1.5),
              ),
              child: Center(
                  child: Text(d.name,
                      style: Mag.numerals(radius * 0.9,
                          color: scheme.onSurface.withValues(alpha: 0.25)))),
            ),
          if (t != null)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: RecordLight(
                      size: radius * 2,
                      drop: 0,
                      label: app.discLabel,
                      strength: 1,
                      spin: spin),
                ),
              ),
            ),
          if (t != null)
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _arm,
                builder: (context, _) => Tonearm(
                  radius: radius,
                  drop: 0,
                  landed: Curves.easeInOut.transform(_arm.value),
                  style: app.armStyle,
                  hand: hand,
                  label: app.discLabel,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ what it is
  Widget _facts(BuildContext context, {bool spread = false}) {
    final b = widget.booth;
    final d = widget.deck;
    final scheme = Theme.of(context).colorScheme;
    final t = d.track;
    final isMaster = identical(b.master, d);
    final chips = <Widget>[
      Text(d.name,
          style: Mag.numerals(22, color: isMaster ? scheme.primary : scheme.onSurface)),
      if (isMaster) const Kicker('master'),
      if (d.bpm != null)
        Text(d.bpm!.toStringAsFixed(1), style: Mag.numerals(16, color: scheme.onSurface)),
      if (d.bpm != null) Text('BPM', style: Mag.flag(8, color: scheme.onSurfaceVariant)),
      if (d.timing?.camelot != null) _KeyChip(deck: d, against: b.other(d)),
      if (t != null && !d.hasBeats) Text('NO GRID', style: Mag.flag(8, color: scheme.outline)),
    ];
    if (!spread) {
      return Wrap(
          spacing: 8,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: chips);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
            spacing: 8,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: chips),
        const SizedBox(height: 3),
        Text(t?.displayTitle ?? 'Nothing on',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Mag.title(16, color: scheme.onSurface)),
        Text(t?.artistLine ?? 'Load a record from the crate',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
      ],
    );
  }

  // ------------------------------------------------------------------ the controls
  Widget _group(BuildContext context, String label, List<Widget> children) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Mag.flag(7.5, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 3),
        Wrap(
            spacing: 5,
            runSpacing: 5,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: children),
      ],
    );
  }

  Widget _transport(BuildContext context) {
    final b = widget.booth;
    final d = widget.deck;
    final t = d.track;
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        _group(context, 'transport', [
          PressButton(label: t == null ? 'Load' : 'Change', onTap: widget.onLoad),
          PressButton(
            label: d.playing ? 'Stop' : 'Play',
            loud: !d.playing && t != null,
            onTap: t == null
                ? null
                : () {
                    feel(Feel.commit);
                    d.playing ? d.pause() : d.play();
                  },
          ),
          PressButton(
            label: 'On the one',
            onTap: t == null || d.playing ? null : () => b.startOnBeat(d),
          ),
        ]),
        _group(context, 'beatmatch', [
          PressButton(
            label: 'Sync',
            onTap: t == null
                ? null
                : () async {
                    final ok = await b.sync(d);
                    if (ok) await b.align(d);
                    if (!context.mounted) return;
                    feel(ok ? Feel.edge : Feel.warn);
                    if (!ok) {
                      ScaffoldMessenger.of(context)
                          .say(snack(const Text('Too far apart to sync, or no grid')));
                    }
                  },
          ),
          PressButton(
              label: '‹',
              onTap: t == null ? null : () => d.nudge(const Duration(milliseconds: -15))),
          PressButton(
              label: '›',
              onTap: t == null ? null : () => d.nudge(const Duration(milliseconds: 15))),
        ]),
      ],
    );
  }

  Widget _cuesAndLoops(BuildContext context) {
    final d = widget.deck;
    final t = d.track;
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        _group(context, 'cues', [
          for (var n = 1; n <= 3; n++)
            PressButton(
              label: d.hotCues.containsKey(n) ? '$n' : 'Set $n',
              loud: d.hotCues.containsKey(n),
              onTap: t == null
                  ? null
                  : () {
                      feel(Feel.pick);
                      d.hotCues.containsKey(n) ? d.jumpCue(n) : d.setCue(n);
                    },
            ),
        ]),
        _group(context, 'loop · bars', [
          for (final bars in const [1, 2, 4, 8])
            PressButton(
              label: '$bars',
              loud: d.loopBars == bars,
              onTap: t == null
                  ? null
                  : () {
                      feel(Feel.pick);
                      d.loopBars == bars ? d.unloop() : d.loop(bars * 4);
                    },
            ),
        ]),
      ],
    );
  }

  /// The pitch fader: per cent, with a hard nought at the middle.
  Widget _pitch(BuildContext context) {
    final d = widget.deck;
    final scheme = Theme.of(context).colorScheme;
    final t = d.track;
    return Row(
      children: [
        Text('PITCH', style: Mag.flag(7.5, color: scheme.onSurfaceVariant)),
        const SizedBox(width: 8),
        Expanded(
          child: CentreSlider(
            value: d.tempo.clamp(0.92, 1.08),
            min: 0.92,
            max: 1.08,
            detent: 0.022,
            onChanged: t == null ? null : d.setTempo,
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 52,
          child: Text(
              '${d.tempo >= 1 ? '+' : ''}${((d.tempo - 1) * 100).toStringAsFixed(1)}%',
              textAlign: TextAlign.right,
              style: Mag.typewriter(10.5,
                  color: d.tempo == 1.0 ? scheme.onSurfaceVariant : scheme.primary)),
        ),
      ],
    );
  }

  /// The three bands, for a phone — on a desk they live in the mixer between the decks.
  Widget _bands(BuildContext context) {
    final b = widget.booth;
    final d = widget.deck;
    final eq = b.eqOf(d);
    if (!b.mixer.canKill) {
      return Text('No kills on this device: the fader alone.',
          style:
              Mag.typewriter(10, color: Theme.of(context).colorScheme.onSurfaceVariant));
    }
    return _group(context, 'eq', [
      for (final (i, label, killed) in [
        (0, 'Low', eq.lowKilled),
        (1, 'Mid', eq.midKilled),
        (2, 'High', eq.highKilled),
      ])
        PressButton(
          label: killed ? '$label ✕' : label,
          loud: killed,
          onTap: d.track == null
              ? null
              : () {
                  feel(Feel.pick);
                  b.kill(d, i, !killed);
                },
        ),
      if (b.mixer.canFilter)
        SizedBox(
          width: 120,
          child: CentreSlider(
            value: b.filters[d] ?? 0,
            onChanged: d.track == null ? null : (v) => b.setFilter(d, v),
          ),
        ),
    ]);
  }
}

/// The key, and whether it sits with the other deck's.
class _KeyChip extends StatelessWidget {
  const _KeyChip({required this.deck, required this.against});
  final engine.Deck deck;
  final engine.Deck against;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = deck.timing, theirs = against.timing;
    final matched =
        mine != null && theirs != null && theirs.camelot != null && mine.inKeyWith(theirs);
    final clashes =
        mine != null && theirs != null && theirs.camelot != null && !matched;
    final colour = matched
        ? scheme.primary
        : clashes
            ? scheme.error
            : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.fromLTRB(5, 1, 5, 0),
      decoration: BoxDecoration(
          border: Border.all(color: colour.withValues(alpha: 0.8)),
          borderRadius: BorderRadius.circular(2)),
      child: Text('${mine?.camelot} · ${mine?.key}${matched ? ' · IN KEY' : ''}',
          style: Mag.typewriter(9.5, color: colour, bold: true)),
    );
  }
}

/// One deck's waveform, reading the room's clock.
class WaveLane extends StatelessWidget {
  const WaveLane({
    super.key,
    required this.booth,
    required this.deck,
    this.height = 72,
    this.window = const Duration(seconds: 22),
    this.mirrored = false,
  });

  final Booth booth;
  final engine.Deck deck;
  final double height;
  final Duration window;

  /// Drawn hanging from the top rather than standing on its foot, so two lanes can
  /// face each other across the phase meter and their beats line up to the eye.
  final bool mirrored;

  @override
  Widget build(BuildContext context) {
    final t = deck.track;
    final auto = booth.auto;
    return WaveStrip(
      position: BoothClock.of(context).positionOf(deck),
      timing: deck.timing,
      bands: t == null ? null : booth.bands[t.id],
      duration: deck.duration ?? Duration.zero,
      playing: deck.playing,
      loop: deck.loopStart != null && deck.loopEnd != null
          ? (deck.loopStart!, deck.loopEnd!)
          : null,
      hotCues: deck.hotCues,
      // Where the booth means to mix out of this record, when it is the one playing.
      markAt: auto.running && identical(booth.master, deck) ? auto.goesAt : null,
      height: height,
      window: window,
      mirrored: mirrored,
      onScrub: t == null ? null : (to) => unawaited(deck.seek(to)),
    );
  }
}
