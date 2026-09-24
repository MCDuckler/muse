import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../api/models.dart';
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
import 'console.dart';

/// One deck of the console: the record turning with its arm, the pitch beside it,
/// and under it what is done to this record alone — as pads, not paragraphs.
class ConsoleDeck extends StatefulWidget {
  const ConsoleDeck({
    super.key,
    required this.booth,
    required this.deck,
    required this.onLoad,
  });

  final Booth booth;
  final engine.Deck deck;

  /// Open the crate for this deck.
  final VoidCallback onLoad;

  @override
  State<ConsoleDeck> createState() => _ConsoleDeckState();
}

class _ConsoleDeckState extends State<ConsoleDeck> with TickerProviderStateMixin {
  late final AnimationController _arm =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
  final _reading = ValueNotifier<ArmReading>(const ArmReading());
  ValueNotifier<Duration>? _position;
  bool _hovering = false;

  /// The deck's edge breathing, in the last seconds before the automix brings this
  /// record in.
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  /// Whether the automix has this record lined up next.
  bool get _incoming {
    final auto = _b.auto;
    return auto.running && _d.loaded && !identical(_b.master, _d) && auto.next?.id == _d.track?.id;
  }
  String? _making;

  engine.Deck get _d => widget.deck;
  Booth get _b => widget.booth;
  Color get _colour => Console.deck(_d.name);

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

  bool get _left => _d.name == 'A';

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
      builder: (context, _) => _plate(isMaster, armed ? Color.lerp(_colour.withValues(alpha: 0.2), _colour, _pulse.value) : null),
    );
  }

  Widget _plate(bool isMaster, Color? pulse) {
    return DragTarget<Track>(
      onWillAcceptWithDetails: (_) {
        setState(() => _hovering = true);
        return true;
      },
      onLeave: (_) => setState(() => _hovering = false),
      onAcceptWithDetails: (d) {
        setState(() => _hovering = false);
        unawaited(_b.load(_d, d.data));
      },
      builder: (context, candidates, rejected) => Plate(
        edge: _hovering ? _colour : pulse ?? (isMaster ? _colour.withValues(alpha: 0.55) : null),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(isMaster),
            const SizedBox(height: 8),
            Expanded(child: _platterAndPitch()),
            const SizedBox(height: 10),
            _transport(),
            const SizedBox(height: 8),
            _pads(),
            const SizedBox(height: 6),
            _parts(),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ what is on
  Widget _header(bool isMaster) {
    final t = _d.track;
    final bpm = _d.bpm;
    final letter = Text(_d.name, style: Mag.numerals(40, color: _colour));
    final words = Expanded(
      child: Column(
        crossAxisAlignment: _left ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t?.displayTitle ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Mag.title(18, color: Console.ink)),
          const SizedBox(height: 2),
          Text(
              _d.trouble != null
                  ? 'Would not load'
                  : t?.artistLine ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Mag.typewriter(11.5, color: _d.trouble != null ? Console.a : Console.quiet)),
        ],
      ),
    );
    final numbers = Column(
      crossAxisAlignment: _left ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(bpm == null ? '—' : bpm.toStringAsFixed(1),
            style: Mag.numerals(30, color: bpm == null ? Console.faint : Console.ink)),
        const SizedBox(height: 3),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isMaster) ...[
              Text('MASTER', style: Console.label(7.5, color: _colour)),
              const SizedBox(width: 6),
            ],
            if (_incoming) ...[
              _NextBadge(booth: _b, colour: _colour),
              const SizedBox(width: 6),
            ],
            if (_d.timing?.camelot != null) _KeyTag(deck: _d, against: _b.other(_d)),
          ],
        ),
      ],
    );
    final gap = const SizedBox(width: 12);
    return SizedBox(
      height: 52,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: _left ? [letter, gap, words, gap, numbers] : [numbers, gap, words, gap, letter],
      ),
    );
  }

  // ------------------------------------------------------------------ the record
  Widget _platterAndPitch() {
    final pitch = _pitch();
    final platter = Expanded(
      child: LayoutBuilder(builder: (context, c) {
        final side = c.biggest.shortestSide.clamp(80.0, 340.0);
        return Center(child: _d.track == null ? _empty(side) : _record(side));
      }),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _left ? [pitch, const SizedBox(width: 10), platter] : [platter, const SizedBox(width: 10), pitch],
    );
  }

  Widget _empty(double side) {
    return SizedBox(
      width: side,
      height: side,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(size: Size.square(side * 0.86), painter: _Dashed(colour: _colour.withValues(alpha: _hovering ? 0.9 : 0.35))),
          Pad(
            label: 'LOAD',
            icon: Icons.album_outlined,
            colour: _colour,
            height: 38,
            width: 110,
            onTap: widget.onLoad,
            tooltip: 'Pick a record, or drag one here from the crate',
          ),
        ],
      ),
    );
  }

  Widget _record(double side) {
    final app = context.read<AppState>();
    final t = _d.track!;
    final radius = side * 0.42;
    final spin = BoothClock.of(context).turnOf(_d);
    final hand = ArmHand(
      reading: _reading,
      onPlace: (at) async {
        await _d.seek(at);
        // With SYNC on, the needle lands in step: moved to the nearest beat.
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
          // The platter the record sits on, ringed in the deck's colour while it turns.
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: radius * 2 + 14,
            height: radius * 2 + 14,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Console.ground,
              border: Border.all(
                  color: _d.playing ? _colour.withValues(alpha: 0.8) : Console.line, width: 2),
              boxShadow: _d.playing
                  ? [BoxShadow(color: _colour.withValues(alpha: 0.18), blurRadius: 24)]
                  : null,
            ),
          ),
          Disc.spinning(
            url: app.api.discUrl(t) ?? Disc.plain(t),
            spin: spin,
            size: radius * 2,
            roll: 0,
            fade: 1,
            label: app.discLabel,
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: RecordLight(size: radius * 2, drop: 0, label: app.discLabel, strength: 1, spin: spin),
              ),
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
    // ±8 %, as on most decks — wider, as a deck's range switch would be, once SYNC or
    // the automix has taken it further.
    final off = (_d.pitch - 1).abs();
    final range = off <= 0.08 ? 0.08 : off <= 0.16 ? 0.16 : 0.5;
    return SizedBox(
      width: 44,
      child: Column(
        children: [
          Text('${pct >= 0 ? '+' : '-'}${pct.abs().toStringAsFixed(1)}',
              style: Mag.typewriter(11, color: pct.abs() < 0.05 ? Console.quiet : _colour, bold: true)),
          const SizedBox(height: 4),
          Expanded(
            child: Tooltip(
              message: 'Pitch · double-click for zero',
              waitDuration: const Duration(milliseconds: 700),
              child: VFader(
                value: _d.pitch.clamp(1 - range, 1 + range),
                min: 1 - range,
                max: 1 + range,
                centre: 1,
                inverted: true,
                colour: _colour,
                onChanged: on ? (v) => _b.pitchByHand(_d, v) : null,
                onDoubleTap: on ? () => _b.pitchByHand(_d, 1) : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ the pads
  Widget _transport() {
    final t = _d.track;
    final on = t != null;
    final play = RoundButton(
      icon: _d.playing ? Icons.pause : Icons.play_arrow,
      colour: _colour,
      lit: _d.playing,
      size: 50,
      tooltip: _d.playing ? 'Pause' : 'Play',
      onTap: on ? () => _d.playing ? _d.pause() : _b.play(_d) : null,
    );
    final small = [
      Pad(
        icon: Icons.start,
        tooltip: 'Start on the master\'s next bar',
        onTap: on && !_d.playing && _b.other(_d).playing ? () => _b.startOnBeat(_d) : null,
        width: 42,
        height: 34,
      ),
      Pad(
        icon: Icons.chevron_left,
        tooltip: 'Nudge back',
        onTap: on ? () => _b.nudge(_d, const Duration(milliseconds: -15)) : null,
        width: 34,
        height: 34,
      ),
      Pad(
        icon: Icons.chevron_right,
        tooltip: 'Nudge on',
        onTap: on ? () => _b.nudge(_d, const Duration(milliseconds: 15)) : null,
        width: 34,
        height: 34,
      ),
      Pad(
        icon: Icons.eject,
        tooltip: 'Another record',
        onTap: widget.onLoad,
        width: 42,
        height: 34,
      ),
    ];
    // Mirrored for B — play at the outer edge on both — but the nudges keep their
    // own order: back is always on the left.
    final group = _left ? small : [small[0], small[2], small[1], small[3]];
    final row = <Widget>[
      play,
      const SizedBox(width: 12),
      for (final (i, p) in group.indexed) ...[if (i > 0) const SizedBox(width: 6), p],
      const Spacer(),
      _syncPad(),
    ];
    return Row(children: _left ? row : row.reversed.toList());
  }

  /// SYNC, as on any deck: pressed, this deck follows the other — tempo and beat,
  /// for as long as it is on. Lit while it is. Pressed again, or the pitch fader
  /// moved, and it lets go.
  Widget _syncPad() {
    final other = _b.other(_d);
    return Pad(
      label: 'SYNC',
      colour: _colour,
      lit: _d.synced,
      width: 72,
      height: 40,
      tooltip: _d.synced
          ? 'Following ${other.name}: tempo and beat · press to let go'
          : 'Follow ${other.name}: its tempo and its beat',
      onTap: _d.track == null || !other.loaded
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
          tooltip: set ? 'Cue $n · right-click to clear' : 'Set cue $n here',
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
            label: bars == 1 ? '1 BAR' : '$bars',
            colour: _colour,
            lit: _d.loopBars == bars,
            tooltip: 'Loop $bars bar${bars == 1 ? '' : 's'}',
            onTap: on ? () => _d.loopBars == bars ? _d.unloop() : _d.loop(bars * 4) : null,
          ),
        );

    const gap = SizedBox(width: 6);
    return Column(
      children: [
        Row(children: [
          _rowMark(Icons.bookmark_outline),
          cue(1), gap, cue(2), gap, cue(3), gap, cue(4),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          _rowMark(Icons.loop),
          loop(1), gap, loop(2), gap, loop(4), gap, loop(8),
        ]),
      ],
    );
  }

  /// What a row of pads is, as an icon at its start rather than a word above it.
  Widget _rowMark(IconData icon) => SizedBox(width: 26, child: Icon(icon, size: 15, color: Console.faint));

  /// The parts of the record: the whole of it, the drums, the music, the record
  /// without its voice and — where this computer has the separator — the voice alone.
  ///
  /// While they are being made, the mark at the row's start turns into how far along
  /// that is, and each pad waiting on it fills along its foot; pointed at, either says
  /// the stage in words. A tick there once they are ready.
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
        // The pads fill with the taking apart itself: nought while it waits its turn
        // or its record is fetched.
        final filled = !going
            ? null
            : job.stage == PartsStage.separating
                ? job.progress ?? 0.0
                : 0.0;
        return LayoutBuilder(builder: (context, box) {
          // Icons and words where both fit, words alone where only they do, and on a
          // narrow deck the icons — which say the rest when pointed at.
          final each = (box.maxWidth - 26 - 6 * (parts.length - 1)) / parts.length;
          final words = each >= 64;
          final icons = each >= 100 || !words;
          return Row(
            children: [
              _partsMark(job),
              for (final (i, (label, part, icon)) in parts.indexed) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(
                  child: Pad(
                    label: going && _making == label && filled! > 0
                        ? '${(filled * 100).floor()}%'
                        : words
                            ? label
                            : null,
                    icon: icons ? icon : null,
                    colour: _colour,
                    lit: t != null && _d.part == part,
                    height: 30,
                    progress: going && part != null && job.parts.contains(part) ? filled : null,
                    tooltip: _partTip(part, job, tooLong),
                    onTap: t == null || _d.makingPart || (part != null && (tooLong || _never(part, job)))
                        ? null
                        : () async {
                            setState(() => _making = label);
                            final done = await _d.swapTo(part, byHand: true);
                            if (!mounted) return;
                            setState(() => _making = done || _d.neverParts.contains(part) ? null : label);
                          },
                  ),
                ),
              ],
            ],
          );
        });
      },
    );
  }

  /// A part this record was told it does not get — and not merely because somebody
  /// cancelled it, which a press puts right.
  bool _never(String part, PartsJob? job) =>
      _d.neverParts.contains(part) && job?.stage != PartsStage.cancelled;

  String _partTip(String? part, PartsJob? job, bool tooLong) {
    final what = switch (part) {
      null => 'The whole record',
      'drums' => 'Just the drums',
      'music' => 'Everything but the drums',
      'instrumental' => 'Everything but the voice',
      _ => 'Just the voice',
    };
    if (part == null) return what;
    if (tooLong) return 'Too long to take apart';
    if (part == 'vocals' && _never(part, job)) return 'The voice alone needs the separator';
    if (_never(part, job)) return 'Not for this record';
    if (job != null && !job.done && job.parts.contains(part)) return '$what · ${stageLine(job)}';
    return what;
  }

  /// The parts row's mark: how the taking apart of this record is going, at a glance.
  Widget _partsMark(PartsJob? job) {
    final Widget mark;
    if (job == null || job.stage == PartsStage.cancelled) {
      return _rowMark(Icons.call_split);
    } else if (job.active) {
      final p = job.stage == PartsStage.fetching && job.total == null ? null : job.progress;
      mark = SizedBox(
        width: 15,
        height: 15,
        child: CircularProgressIndicator(
          value: p,
          strokeWidth: 2,
          color: _colour,
          backgroundColor: Console.line,
        ),
      );
    } else if (job.stage == PartsStage.waiting) {
      mark = const Icon(Icons.hourglass_empty, size: 14, color: Console.quiet);
    } else if (job.stage == PartsStage.ready) {
      mark = Icon(Icons.check, size: 15, color: _colour);
    } else {
      mark = const Icon(Icons.error_outline, size: 15, color: Console.a);
    }
    return Tooltip(
      message: stageLine(job),
      waitDuration: const Duration(milliseconds: 300),
      child: SizedBox(width: 26, child: Center(child: mark)),
    );
  }
}

/// A record's key, lit when it sits with the other deck's.
class _KeyTag extends StatelessWidget {
  const _KeyTag({required this.deck, required this.against});
  final engine.Deck deck;
  final engine.Deck against;

  @override
  Widget build(BuildContext context) {
    final mine = deck.timing!, theirs = against.timing;
    final ok = theirs != null && theirs.camelot != null && mine.inKeyWith(theirs);
    final c = ok ? Console.deck(deck.name) : Console.quiet;
    return Tooltip(
      message: mine.key ?? '',
      child: Container(
        padding: const EdgeInsets.fromLTRB(5, 1, 5, 1),
        decoration: BoxDecoration(
          border: Border.all(color: c.withValues(alpha: 0.8)),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(mine.camelot!, style: Mag.typewriter(10.5, color: c, bold: true)),
      ),
    );
  }
}

class _Dashed extends CustomPainter {
  _Dashed({required this.colour});
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final p = Paint()
      ..color = colour
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    const n = 64;
    for (var i = 0; i < n; i += 2) {
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), i / n * 6.2832, 1 / n * 6.2832, false, p);
    }
  }

  @override
  bool shouldRepaint(_Dashed old) => old.colour != colour;
}

/// This record is next: and in how long, counted down.
class _NextBadge extends StatelessWidget {
  const _NextBadge({required this.booth, required this.colour});
  final Booth booth;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: BoothClock.of(context).positionOf(booth.master),
      builder: (context, _) {
        final left = booth.auto.timeToGo;
        final going = booth.inTransition || (left?.isNegative ?? false);
        final s = left?.inSeconds;
        return Container(
          padding: const EdgeInsets.fromLTRB(5, 1, 5, 1),
          decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(3)),
          child: Text(
            going
                ? 'IN'
                : s == null
                    ? 'NEXT'
                    : 'NEXT ${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}',
            style: Console.label(7.5, color: Console.ground),
          ),
        );
      },
    );
  }
}
