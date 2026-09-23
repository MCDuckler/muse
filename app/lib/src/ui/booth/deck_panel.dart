import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
import 'wave_strip.dart';

/// One deck in the room: the record turning, the arm on it, the song's shape
/// running under the needle, and the few things done to this record alone.
///
/// The record is the app's own — the same pressing, the same light on it, the same
/// arm you can pick up — driven by a motor with weight: it comes up to speed over a
/// third of a second and coasts down over half of one, at the deck's tempo, so a
/// record pitched up visibly turns faster.
class DeckPanel extends StatefulWidget {
  const DeckPanel({
    super.key,
    required this.booth,
    required this.deck,
    required this.onLoad,
    this.compact = false,
  });

  final Booth booth;
  final engine.Deck deck;
  final VoidCallback onLoad;

  /// A phone: the record smaller, the strip shorter.
  final bool compact;

  @override
  State<DeckPanel> createState() => _DeckPanelState();
}

class _DeckPanelState extends State<DeckPanel> with TickerProviderStateMixin {
  late final AnimationController _spin = AnimationController.unbounded(vsync: this);
  late final Ticker _motor = createTicker(_turn);
  late final AnimationController _arm =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 600));

  /// 33⅓: one turn every 1.8 s, the speed the record would really run.
  static const _fullSpeed = 1 / 1.8;
  double _speed = 0;
  Duration? _lastTick;

  final _position = ValueNotifier<Duration>(Duration.zero);
  final _reading = ValueNotifier<ArmReading>(const ArmReading());

  @override
  void initState() {
    super.initState();
    _motor.start();
    widget.deck.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    widget.deck.removeListener(_changed);
    _motor.dispose();
    _spin.dispose();
    _arm.dispose();
    _position.dispose();
    _reading.dispose();
    super.dispose();
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

  /// Every frame: the motor, and the clocks the strip and the arm read.
  void _turn(Duration elapsed) {
    final last = _lastTick;
    _lastTick = elapsed;
    if (last == null) return;
    final dt = (elapsed - last).inMicroseconds / 1e6;
    final d = widget.deck;
    final want = d.playing ? _fullSpeed * d.tempo : 0.0;
    // Up over a third of a second, down over half: a platter has weight.
    final tau = want > _speed ? 0.33 : 0.5;
    _speed += (want - _speed) * (1 - _expNeg(dt / tau));
    if (_speed.abs() > 1e-4) _spin.value = (_spin.value + _speed * dt) % 1024;
    final at = d.position;
    if (at != _position.value) {
      _position.value = at;
      _reading.value = ArmReading(position: at, length: d.duration, playing: d.playing);
    }
  }

  static double _expNeg(double x) => x > 20 ? 0 : 1 / _exp(x);
  static double _exp(double x) {
    var sum = 1.0, term = 1.0;
    for (var i = 1; i < 12; i++) {
      term *= x / i;
      sum += term;
    }
    return sum;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final b = widget.booth;
    final d = widget.deck;
    final scheme = Theme.of(context).colorScheme;
    final t = d.track;
    final isMaster = identical(b.master, d);
    final kills = b.kills[d] ?? (low: false, mid: false, high: false);
    final side = widget.compact ? 112.0 : 168.0;
    final radius = side * 0.42;
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

    final record = SizedBox(
      width: side,
      height: side,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          if (t != null)
            Disc.spinning(
              url: app.api.discUrl(t) ?? Disc.plain(t),
              spin: _spin,
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
                border: Border.all(color: scheme.onSurface.withValues(alpha: 0.25), width: 1.5),
              ),
              child: Center(
                  child: Text(d.name, style: Mag.numerals(radius * 0.9, color: scheme.onSurface.withValues(alpha: 0.25)))),
            ),
          if (t != null)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: RecordLight(
                      size: radius * 2, drop: 0, label: app.discLabel, strength: 1, spin: _spin),
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

    final facts = <Widget>[
      Text(d.name, style: Mag.numerals(22, color: isMaster ? scheme.primary : scheme.onSurface)),
      if (isMaster) Kicker('master'),
      if (d.bpm != null)
        Text(d.bpm!.toStringAsFixed(1), style: Mag.numerals(16, color: scheme.onSurface)),
      if (d.bpm != null) Text('BPM', style: Mag.flag(8, color: scheme.onSurfaceVariant)),
      if (d.timing?.camelot != null) _KeyChip(deck: d, against: b.other(d)),
      if (d.tempo != 1.0)
        Text('${d.tempo >= 1 ? '+' : ''}${((d.tempo - 1) * 100).toStringAsFixed(1)}%',
            style: Mag.typewriter(11, color: scheme.primary)),
      if (t != null && !d.hasBeats) Text('NO GRID', style: Mag.flag(8, color: scheme.outline)),
    ];

    return Container(
      decoration: BoxDecoration(
        border: Border.all(
            color: isMaster ? scheme.primary : scheme.onSurface.withValues(alpha: 0.35),
            width: isMaster ? 1.5 : 1),
        borderRadius: BorderRadius.circular(3),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              record,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: facts),
                    const SizedBox(height: 2),
                    Text(t?.displayTitle ?? 'Nothing on',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.title(15, color: scheme.onSurface)),
                    if (t != null)
                      Text(t.artistLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
                    const SizedBox(height: 6),
                    WaveStrip(
                      position: _position,
                      timing: d.timing,
                      bands: t == null ? null : b.bands[t.id],
                      duration: d.duration ?? Duration.zero,
                      playing: d.playing,
                      loop: d.loopStart != null && d.loopEnd != null ? (d.loopStart!, d.loopEnd!) : null,
                      hotCues: d.hotCues,
                      height: widget.compact ? 56 : 72,
                      window: Duration(seconds: widget.compact ? 14 : 22),
                      onScrub: t == null ? null : (to) => unawaited(d.seek(to)),
                    ),
                    ValueListenableBuilder<Duration>(
                      valueListenable: _position,
                      builder: (context, at, _) => Text(
                        '${_clock(at)}  /  ${_clock(d.duration ?? Duration.zero)}',
                        style: Mag.typewriter(10.5, color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // The filter, where the mixer has one: closed to the left, open in the
          // middle, closed to the right — the one knob a DJ reaches for mid-blend.
          if (b.mixer.canFilter && t != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Text('FILTER', style: Mag.flag(8, color: scheme.onSurfaceVariant)),
                  Expanded(
                    child: Slider(
                      value: b.filters[d] ?? 0,
                      min: -1,
                      max: 1,
                      divisions: 40,
                      onChanged: (v) => b.setFilter(d, v.abs() < 0.06 ? 0 : v),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          // What is done to this record alone.
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
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
              _Nudge(deck: d, enabled: t != null),
              PressButton(
                label: d.loopStart == null ? 'Loop 4' : 'Unloop',
                loud: d.loopStart != null,
                onTap: t == null ? null : () => d.loopStart == null ? d.loop(4) : d.unloop(),
              ),
              for (var n = 1; n <= 2; n++)
                PressButton(
                  label: d.hotCues.containsKey(n) ? 'Cue $n' : 'Set $n',
                  onTap: t == null
                      ? null
                      : () => d.hotCues.containsKey(n) ? d.jumpCue(n) : d.setCue(n),
                ),
              const SizedBox(width: 6),
              for (final (label, on, set) in [
                ('Low', kills.low, (bool v) => b.setKills(d, low: v, mid: kills.mid, high: kills.high)),
                ('Mid', kills.mid, (bool v) => b.setKills(d, low: kills.low, mid: v, high: kills.high)),
                ('High', kills.high, (bool v) => b.setKills(d, low: kills.low, mid: kills.mid, high: v)),
              ])
                PressButton(
                  label: on ? '$label ✕' : label,
                  loud: on,
                  onTap: b.mixer.canKill && t != null
                      ? () {
                          feel(Feel.pick);
                          set(!on);
                        }
                      : null,
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _clock(Duration d) {
    final m = d.inMinutes, s = d.inSeconds.remainder(60);
    return '$m:${s.toString().padLeft(2, '0')}';
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
    final matched = mine != null && theirs != null && theirs.camelot != null && mine.inKeyWith(theirs);
    final clashes = mine != null && theirs != null && theirs.camelot != null && !matched;
    final colour = matched ? scheme.primary : clashes ? scheme.error : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.fromLTRB(5, 1, 5, 0),
      decoration: BoxDecoration(border: Border.all(color: colour.withValues(alpha: 0.8)), borderRadius: BorderRadius.circular(2)),
      child: Text('${mine?.camelot} · ${mine?.key}${matched ? ' · IN KEY' : ''}',
          style: Mag.typewriter(9.5, color: colour, bold: true)),
    );
  }
}

/// A nudge either way: the DJ's hand on the platter's edge.
class _Nudge extends StatelessWidget {
  const _Nudge({required this.deck, required this.enabled});
  final engine.Deck deck;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PressButton(label: '‹', onTap: enabled ? () => deck.nudge(const Duration(milliseconds: -20)) : null),
        const SizedBox(width: 2),
        PressButton(label: '›', onTap: enabled ? () => deck.nudge(const Duration(milliseconds: 20)) : null),
      ],
    );
  }
}
