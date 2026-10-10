import 'dart:async';

import 'package:flutter/material.dart';

import '../../../api/models.dart';
import '../../../state/booth/booth.dart';
import '../../../state/booth/deck.dart' as engine;
import '../../snack.dart';
import 'console.dart';

/// The cue check: records to check by ear, so the booth's guesses — its grid and the
/// pads it places — can be measured against a DJ instead of against each other.
///
/// Load one, move pad 1 to where the record is on and pad 4 to where you would leave
/// it (pads moved by hand are kept for the record anyway), then say what the grid is
/// like. The house keeps where every pad was left and whether it was the booth's own
/// place; that is the ground truth the cue and grid rules are tuned against.
class CueCheckList extends StatefulWidget {
  const CueCheckList({super.key, required this.booth, required this.row});
  final Booth booth;
  final Widget Function(Track track, String? note) row;

  @override
  State<CueCheckList> createState() => _CueCheckListState();
}

/// What a record's grid was like, as the buttons say it.
const gridVerdicts = <(String, String, String)>[
  ('ok', 'GRID OK', 'The beat, the bars and the four-bar lines are where they should be'),
  ('double', '×2 FAST', 'The tempo shown is twice the record\'s'),
  ('half', '÷2 SLOW', 'The tempo shown is half the record\'s'),
  ('off', 'OFF BEAT', 'The right tempo, but the beat lines sit between the beats'),
  ('one', 'ONE WRONG', 'The beat is right but the bar starts on the wrong beat'),
  ('other', 'OTHER', 'Something else: a wrong tempo, a grid that drifts, no beat at all'),
];

class _CueCheckListState extends State<CueCheckList> {
  List<CueCheck>? _items;
  String? _trouble;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    widget.booth.addListener(_decks);
    unawaited(_ask());
  }

  @override
  void dispose() {
    widget.booth.removeListener(_decks);
    super.dispose();
  }

  void _decks() {
    if (mounted) setState(() {});
  }

  Future<void> _ask() async {
    try {
      final got = await widget.booth.api.cueCheck();
      if (mounted) setState(() => _items = got.items);
    } catch (e) {
      if (mounted) setState(() => _trouble = '$e');
    }
  }

  engine.Deck? _deckWith(Track t) {
    for (final d in widget.booth.decks) {
      if (d.track?.id == t.id) return d;
    }
    return null;
  }

  Future<void> _check(CueCheck c, engine.Deck d, String grid) async {
    setState(() => _saving = true);
    try {
      await widget.booth.api.checkCues(c.track.id, grid: grid, pads: {
        for (final e in d.hotCues.entries)
          e.key: (ms: e.value.inMilliseconds, auto: d.padWhy.containsKey(e.key)),
      });
      await _ask();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).say(snack(Text('Not kept: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _undo(CueCheck c) async {
    try {
      await widget.booth.api.uncheckCues(c.track.id);
      await _ask();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items == null) {
      return Center(
          child: Text(_trouble == null ? 'ASKING THE HOUSE…' : 'COULD NOT ASK: $_trouble',
              textAlign: TextAlign.center, style: Console.label(8.5, color: Console.faint)));
    }
    final done = items.where((i) => i.checked).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 4),
        child: Text('CHECK BY EAR · $done OF ${items.length} DONE',
            style: Console.label(8.5, color: Console.quiet)),
      ),
      Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 6),
        child: Text(
            'Load one. Put pad 1 where it is on and pad 4 where you would leave it '
            '(right-click a pad to clear it, click again to set it where the record is), '
            'then say what the grid is like.',
            style: Console.label(8, color: Console.faint)),
      ),
      Expanded(
        child: ListView(children: [
          for (final c in items) ...[
            widget.row(c.track, c.checked ? 'checked · ${_said(c.grid)}' : null),
            if (_deckWith(c.track) case final d? when !c.checked)
              _Verdicts(deck: d, busy: _saving, onPick: (g) => _check(c, d, g)),
            if (c.checked && _deckWith(c.track) != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _undo(c),
                  child: Text('CHECK AGAIN', style: Console.label(8, color: Console.quiet)),
                ),
              ),
          ],
        ]),
      ),
    ]);
  }

  static String _said(String? grid) {
    for (final (v, label, _) in gridVerdicts) {
      if (v == grid) return label.toLowerCase();
    }
    return 'no word on the grid';
  }
}

class _Verdicts extends StatelessWidget {
  const _Verdicts({required this.deck, required this.busy, required this.onPick});
  final engine.Deck deck;
  final bool busy;
  final void Function(String grid) onPick;

  @override
  Widget build(BuildContext context) {
    final c = Console.deck(deck.name);
    String pad(int n) {
      final at = deck.hotCues[n];
      if (at == null) return '$n —';
      final m = at.inMinutes, s = at.inSeconds % 60;
      return '$n ${deck.padWhy.containsKey(n) ? 'booth' : 'yours'} $m:${s.toString().padLeft(2, '0')}';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 4, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('ON DECK ${deck.name} · PADS ${pad(1)} · ${pad(4)}', style: Console.label(8, color: c)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final (v, label, tip) in gridVerdicts)
            SizedBox(
              height: 28,
              child: Pad(
                label: label,
                colour: c,
                height: 28,
                tooltip: tip,
                onTap: busy ? null : () => onPick(v),
              ),
            ),
        ]),
      ]),
    );
  }
}
