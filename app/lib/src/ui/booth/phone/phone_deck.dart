import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../state/app_state.dart';
import '../../../state/booth/booth.dart';
import '../../../state/booth/deck.dart' as engine;
import '../../../worker/parts_jobs.dart';
import '../../../worker/render_parts.dart' show upToSeconds;
import '../../mag.dart';
import '../../record_stage.dart' show Disc, RecordLight, Tonearm;
import '../../snack.dart';
import '../../stage/arm_grip.dart';
import '../booth_clock.dart';
import '../desk/console.dart';
import '../meters.dart' show CentreSlider;

/// One deck of the phone's console: half the width of the screen, and everything
/// the desk's deck has in it — the record turning with its arm on it, the pitch, the
/// transport, SYNC, the cues, the loops, the parts — as pads a thumb can hit.
class PhoneDeck extends StatefulWidget {
  const PhoneDeck({super.key, required this.booth, required this.deck, required this.onLoad});
  final Booth booth;
  final engine.Deck deck;
  final VoidCallback onLoad;

  @override
  State<PhoneDeck> createState() => _PhoneDeckState();
}

class _PhoneDeckState extends State<PhoneDeck> with TickerProviderStateMixin {
  late final AnimationController _arm = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  final _reading = ValueNotifier<ArmReading>(const ArmReading());
  ValueNotifier<Duration>? _position;

  engine.Deck get _d => widget.deck;
  Booth get _b => widget.booth;
  Color get _colour => Console.deck(_d.name);

  bool get _incoming {
    final auto = _b.auto;
    return auto.running && _d.loaded && !identical(_b.master, _d) && auto.next?.id == _d.track?.id;
  }

  @override
  void initState() {
    super.initState();
    _d.addListener(_changed);
    _changed();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final now = BoothClock.of(context).positionOf(_d);
    if (identical(now, _position)) return;
    _position?.removeListener(_moved);
    _position = now..addListener(_moved);
  }

  @override
  void dispose() {
    _position?.removeListener(_moved);
    _d.removeListener(_changed);
    _arm.dispose();
    _pulse.dispose();
    _reading.dispose();
    super.dispose();
  }

  void _moved() {
    _reading.value = ArmReading(position: _position!.value, length: _d.duration, playing: _d.playing);
  }

  void _changed() {
    _d.playing ? _arm.forward() : _arm.reverse();
    final t = _d.track;
    if (t != null && !_b.bands.containsKey(t.id)) {
      unawaited(_b.fetchBands(t).then((_) {
        if (mounted) setState(() {});
      }));
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isMaster = identical(_b.master, _d) && _d.loaded;
    final left = _b.auto.timeToGo;
    final armed = _incoming && left != null && left.inSeconds < 16 && !_b.inTransition;
    if (armed && !_pulse.isAnimating) _pulse.repeat(reverse: true);
    if (!armed && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) => Plate(
        edge: armed ? Color.lerp(_colour.withValues(alpha: 0.2), _colour, _pulse.value) : (isMaster ? _colour.withValues(alpha: 0.55) : null),
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(isMaster),
            const SizedBox(height: 6),
            Center(child: _d.track == null ? _empty(96) : _record(96)),
            const SizedBox(height: 6),
            _pitch(),
            const SizedBox(height: 6),
            _transport(),
            const SizedBox(height: 5),
            _pads(),
            const SizedBox(height: 5),
            _parts(),
          ],
        ),
      ),
    );
  }

  Widget _header(bool isMaster) {
    final t = _d.track;
    final bpm = _d.bpm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(_d.name, style: Mag.numerals(22, color: _colour)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t?.displayTitle ?? 'Nothing on',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.title(12, color: t == null ? Console.faint : Console.ink)),
                  Text(_d.trouble != null ? 'Would not load' : t?.artistLine ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Mag.typewriter(9.5, color: _d.trouble != null ? Console.a : Console.quiet)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Row(
          children: [
            Text(bpm == null ? '—' : bpm.toStringAsFixed(1), style: Mag.numerals(17, color: bpm == null ? Console.faint : Console.ink)),
            const SizedBox(width: 6),
            if (isMaster) ...[Text('MASTER', style: Console.label(7.5, color: _colour)), const SizedBox(width: 5)],
            if (_incoming) ...[_NextBadge(booth: _b, colour: _colour), const SizedBox(width: 5)],
            if (_d.timing?.camelot != null) _KeyTag(deck: _d, against: _b.other(_d)),
          ],
        ),
      ],
    );
  }

  Widget _empty(double side) => SizedBox(
        width: side,
        height: side,
        child: Center(
          child: Pad(
            label: 'LOAD',
            icon: Icons.album_outlined,
            colour: _colour,
            height: 34,
            width: 88,
            onTap: widget.onLoad,
          ),
        ),
      );

  Widget _record(double side) {
    final app = context.read<AppState>();
    final t = _d.track!;
    final radius = side * 0.44;
    final spin = BoothClock.of(context).turnOf(_d);
    final hand = ArmHand(
      reading: _reading,
      onPlace: (at) async {
        await _d.seek(at);
        if (!_d.playing) await _b.play(_d, bars: false);
      },
      onPark: _d.pause,
    );
    return SizedBox(
      width: side,
      height: side,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: radius * 2 + 8,
            height: radius * 2 + 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Console.ground,
              border: Border.all(color: _d.playing ? _colour.withValues(alpha: 0.8) : Console.line, width: 1.5),
              boxShadow: _d.playing ? [BoxShadow(color: _colour.withValues(alpha: 0.18), blurRadius: 16)] : null,
            ),
          ),
          Disc.spinning(url: app.api.discUrl(t) ?? Disc.plain(t), spin: spin, size: radius * 2, roll: 0, fade: 1, label: app.discLabel),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: RecordLight(size: radius * 2, drop: 0, label: app.discLabel, strength: 1, spin: spin)),
            ),
          ),
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

  Widget _pitch() {
    final on = _d.track != null;
    final pct = (_d.pitch - 1) * 100;
    final off = (_d.pitch - 1).abs();
    final range = off <= 0.08 ? 0.08 : off <= 0.16 ? 0.16 : 0.5;
    return Row(
      children: [
        Text('PITCH', style: Console.label(7.5)),
        const SizedBox(width: 6),
        Expanded(
          child: CentreSlider(
            value: _d.pitch.clamp(1 - range, 1 + range),
            min: 1 - range,
            max: 1 + range,
            detent: range * 0.05,
            height: 20,
            onChanged: on ? (v) => _b.pitchByHand(_d, v) : null,
          ),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 36,
          child: Text('${pct >= 0 ? '+' : '-'}${pct.abs().toStringAsFixed(1)}',
              textAlign: TextAlign.right,
              style: Mag.typewriter(9.5, color: pct.abs() < 0.05 ? Console.quiet : _colour, bold: true)),
        ),
      ],
    );
  }

  Widget _transport() {
    final t = _d.track;
    final on = t != null;
    final other = _b.other(_d);
    return Column(
      children: [
        Row(
          children: [
            RoundButton(
              icon: _d.playing ? Icons.pause : Icons.play_arrow,
              colour: _colour,
              lit: _d.playing,
              size: 40,
              tooltip: _d.playing ? 'Pause' : 'Play',
              onTap: on ? () => _d.playing ? _d.pause() : _b.play(_d) : null,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Pad(
                icon: Icons.start,
                height: 30,
                tooltip: 'Start on the master\'s next bar',
                onTap: on && !_d.playing && other.playing ? () => _b.startOnBeat(_d) : null,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Pad(icon: Icons.eject, height: 30, tooltip: 'Another record', onTap: widget.onLoad),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Pad(
                icon: Icons.chevron_left,
                height: 30,
                tooltip: 'Nudge back',
                onTap: on ? () => _b.nudge(_d, const Duration(milliseconds: -15)) : null,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Pad(
                icon: Icons.chevron_right,
                height: 30,
                tooltip: 'Nudge on',
                onTap: on ? () => _b.nudge(_d, const Duration(milliseconds: 15)) : null,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              flex: 2,
              child: Pad(
                label: 'SYNC',
                colour: _colour,
                lit: _d.synced,
                height: 30,
                tooltip: _d.synced ? 'Following ${other.name} · press to let go' : 'Follow ${other.name}: its tempo and its beat',
                onTap: !on || !other.loaded
                    ? null
                    : () async {
                        if (_d.synced) {
                          await _b.setSync(_d, false);
                          return;
                        }
                        final why = _b.whyNotSync(_d);
                        final ok = why == null && await _b.setSync(_d, true);
                        if (!mounted || ok) return;
                        ScaffoldMessenger.of(context).say(snack(Text(why ?? 'Could not sync')));
                      },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _pads() {
    final on = _d.track != null;
    Widget cue(int n) {
      final set = _d.hotCues.containsKey(n);
      return Expanded(
        child: Pad(
          label: '$n',
          colour: _colour,
          dim: set,
          height: 28,
          tooltip: set ? 'Cue $n · hold to clear' : 'Set cue $n here',
          onTap: on ? () => set ? _d.jumpCue(n) : _d.setCue(n) : null,
          onLongPress: set
              ? () {
                  _d.hotCues.remove(n);
                  _d.changed();
                }
              : null,
        ),
      );
    }

    Widget loop(int bars) => Expanded(
          child: Pad(
            label: bars == 1 ? '1' : '$bars',
            colour: _colour,
            lit: _d.loopBars == bars,
            height: 28,
            tooltip: 'Loop $bars bar${bars == 1 ? '' : 's'}',
            onTap: on ? () => _d.loopBars == bars ? _d.unloop() : _d.loop(bars * 4) : null,
          ),
        );
    const gap = SizedBox(width: 4);
    return Column(
      children: [
        Row(children: [_mark(Icons.bookmark_outline), cue(1), gap, cue(2), gap, cue(3), gap, cue(4)]),
        const SizedBox(height: 4),
        Row(children: [_mark(Icons.loop), loop(1), gap, loop(2), gap, loop(4), gap, loop(8)]),
      ],
    );
  }

  Widget _mark(IconData icon) => SizedBox(width: 18, child: Icon(icon, size: 12, color: Console.faint));

  Widget _parts() {
    return ListenableBuilder(
      listenable: partsJobs,
      builder: (context, _) {
        final t = _d.track;
        final job = t == null ? null : partsJobs.of(t.id);
        final going = job != null && !job.done;
        final tooLong = t != null && (t.durationMs ?? 0) > upToSeconds * 1000;
        final parts = <(String, String?, IconData)>[
          ('WHOLE', null, Icons.album),
          ('DRUMS', 'drums', Icons.graphic_eq),
          ('MUSIC', 'music', Icons.piano),
          ('NO VOX', 'instrumental', Icons.mic_off),
          if (_b.parts.separatesHere) ('VOCALS', 'vocals', Icons.mic),
        ];
        final filled = !going ? null : (job.stage == PartsStage.separating ? job.progress ?? 0.0 : 0.0);
        Widget mark;
        if (job == null || job.stage == PartsStage.cancelled) {
          mark = _mark(Icons.call_split);
        } else if (job.active) {
          mark = SizedBox(
            width: 18,
            child: Center(
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  value: job.stage == PartsStage.fetching && job.total == null ? null : job.progress,
                  strokeWidth: 2,
                  color: _colour,
                  backgroundColor: Console.line,
                ),
              ),
            ),
          );
        } else {
          mark = _mark(job.stage == PartsStage.ready ? Icons.check : job.stage == PartsStage.waiting ? Icons.hourglass_empty : Icons.error_outline);
        }
        return Row(
          children: [
            Tooltip(message: job == null ? 'The parts of the record' : stageLine(job), child: mark),
            for (final (i, (label, part, icon)) in parts.indexed) ...[
              if (i > 0) const SizedBox(width: 4),
              Expanded(
                child: Pad(
                  icon: icon,
                  colour: _colour,
                  lit: t != null && _d.part == part,
                  height: 28,
                  progress: going && part != null && job.parts.contains(part) ? filled : null,
                  tooltip: tooLong && part != null ? 'Too long to take apart' : label,
                  onTap: t == null || _d.makingPart || (part != null && (tooLong || (_d.neverParts.contains(part) && job?.stage != PartsStage.cancelled)))
                      ? null
                      : () async {
                          await _d.swapTo(part, byHand: true);
                          if (mounted) setState(() {});
                        },
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _KeyTag extends StatelessWidget {
  const _KeyTag({required this.deck, required this.against});
  final engine.Deck deck;
  final engine.Deck against;

  @override
  Widget build(BuildContext context) {
    final mine = deck.timing!, theirs = against.timing;
    final ok = theirs != null && theirs.camelot != null && mine.inKeyWith(theirs);
    final c = ok ? Console.deck(deck.name) : Console.quiet;
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 1, 4, 1),
      decoration: BoxDecoration(border: Border.all(color: c.withValues(alpha: 0.8)), borderRadius: BorderRadius.circular(3)),
      child: Text(mine.camelot!, style: Mag.typewriter(9.5, color: c, bold: true)),
    );
  }
}

class _NextBadge extends StatelessWidget {
  const _NextBadge({required this.booth, required this.colour});
  final Booth booth;
  final Color colour;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: BoothClock.of(context).positionOf(booth.master),
        builder: (context, _) {
          final left = booth.auto.timeToGo;
          final going = booth.inTransition || (left?.isNegative ?? false);
          final s = left?.inSeconds;
          return Container(
            padding: const EdgeInsets.fromLTRB(4, 1, 4, 1),
            decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(3)),
            child: Text(going ? 'IN' : s == null ? 'NEXT' : 'NEXT ${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}',
                style: Console.label(7.5, color: Console.ground)),
          );
        },
      );
}
