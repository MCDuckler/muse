import 'dart:async';

import 'package:flutter/material.dart';

import '../../../state/booth/booth.dart';
import '../../../state/booth/deck.dart' as engine;
import '../../../state/booth/mixer.dart';
import '../../feel.dart';
import '../../mag.dart';
import '../desk/console.dart';
import '../desk/console_mixer.dart' show Crossfader, MixButton;
import '../meters.dart' show LevelMeter;

/// The mixer on a phone: both channels across one strip — each its four knobs and a
/// short fader with its meter — the crossfader under them, and the MIX button with
/// how it mixes beside it.
class PhoneMixer extends StatefulWidget {
  const PhoneMixer({super.key, required this.booth});
  final Booth booth;

  @override
  State<PhoneMixer> createState() => _PhoneMixerState();
}

class _PhoneMixerState extends State<PhoneMixer> {
  Transition _kind = Transition.blend;
  int _bars = 16;

  Booth get _b => widget.booth;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final from = _b.master, to = _b.other(from);
    final ready = _b.a.loaded && _b.b.loaded && from.playing;
    return Plate(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _Channel(booth: _b, deck: _b.a)),
              Container(width: 1, height: 84, color: Console.line, margin: const EdgeInsets.symmetric(horizontal: 8)),
              Expanded(child: _Channel(booth: _b, deck: _b.b, mirrored: true)),
            ],
          ),
          const SizedBox(height: 6),
          Crossfader(booth: _b),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: MixButton(
                    going: _b.inTransition,
                    arming: _b.arming?.startsAt,
                    ready: ready,
                    accent: accent,
                    from: from.name,
                    to: to.name,
                    onTap: () {
                      if (_b.busy) {
                        _b.stopTransition();
                      } else {
                        unawaited(_b.go(_kind, bars: _bars));
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _how(accent),
            ],
          ),
        ],
      ),
    );
  }

  /// How the MIX button mixes: a chip that opens the choices.
  Widget _how(Color accent) => PopupMenuButton<Object>(
        tooltip: 'How to mix',
        color: Console.raised,
        position: PopupMenuPosition.under,
        onSelected: (v) => setState(() {
          feel(Feel.pick);
          if (v is Transition) _kind = v;
          if (v is int) _bars = v;
        }),
        itemBuilder: (context) => [
          for (final k in Transition.values)
            PopupMenuItem<Object>(
              value: k,
              height: 34,
              child: Row(children: [
                Icon(transitionIcon(k), size: 15, color: k == _kind ? accent : Console.quiet),
                const SizedBox(width: 10),
                Text(k.label.toUpperCase(), style: Console.label(10, color: k == _kind ? accent : Console.ink)),
              ]),
            ),
          const PopupMenuDivider(),
          for (final n in const [4, 8, 16, 32])
            PopupMenuItem<Object>(
              value: n,
              height: 32,
              child: Text('$n BARS', style: Console.label(10, color: n == _bars ? accent : Console.ink)),
            ),
        ],
        child: Container(
          height: 46,
          width: 118,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: Console.raised, borderRadius: BorderRadius.circular(6), border: Border.all(color: Console.line)),
          child: Row(
            children: [
              Icon(transitionIcon(_kind), size: 14, color: Console.ink),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_kind.label.toUpperCase(), maxLines: 1, overflow: TextOverflow.clip, style: Console.label(8, color: Console.ink)),
                    Row(children: [
                      Text('$_bars', style: Mag.numerals(12, color: Console.ink)),
                      const SizedBox(width: 3),
                      Text('BARS', style: Console.label(7.5)),
                    ]),
                  ],
                ),
              ),
              const Icon(Icons.expand_more, size: 14, color: Console.quiet),
            ],
          ),
        ),
      );
}

/// One channel, across: the four knobs in a row over the fader and its meter.
class _Channel extends StatelessWidget {
  const _Channel({required this.booth, required this.deck, this.mirrored = false});
  final Booth booth;
  final engine.Deck deck;
  final bool mirrored;

  @override
  Widget build(BuildContext context) {
    final c = Console.deck(deck.name);
    final eq = booth.eqOf(deck);
    final on = deck.track != null;
    final canKill = booth.mixer.canKill;
    final level = identical(deck, booth.a) ? booth.levels.a : booth.levels.b;

    Widget band(int i, String label, double db) {
      final killed = db <= EqSet.killed;
      return Knob(
        value: EqSet.knobOf(db),
        min: 0,
        max: 1,
        rest: 0.5,
        label: killed ? 'KILL' : label,
        colour: killed ? Console.a : c,
        size: 28,
        onChanged: !on || !canKill
            ? null
            : (t) {
                final d = EqSet.dbOf(t);
                booth.setEq(deck, switch (i) { 0 => eq.withLow(d), 1 => eq.withMid(d), _ => eq.withHigh(d) });
              },
      );
    }

    final knobs = Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        band(2, 'HI', eq.high),
        band(1, 'MID', eq.mid),
        band(0, 'LOW', eq.low),
        Knob(
          value: booth.filters[deck] ?? 0,
          label: 'FLT',
          colour: c,
          size: 28,
          onChanged: on && booth.mixer.canFilter ? (v) => booth.setFilter(deck, v) : null,
        ),
      ],
    );
    final fader = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(deck.name, style: Mag.numerals(14, color: c)),
        const SizedBox(width: 6),
        SizedBox(
          height: 64,
          child: VFader(value: booth.gainOf(deck), colour: c, width: 24, onChanged: (v) => booth.setGain(deck, v), onDoubleTap: () => booth.setGain(deck, 1)),
        ),
        const SizedBox(width: 4),
        LevelMeter(deck: deck, bands: deck.track == null ? null : booth.bands[deck.track!.id], level: level, width: 6, height: 64),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        knobs,
        const SizedBox(height: 4),
        Align(alignment: mirrored ? Alignment.centerRight : Alignment.centerLeft, child: fader),
      ],
    );
  }
}
