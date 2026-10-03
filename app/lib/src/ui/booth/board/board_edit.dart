// A pad's settings: its name, its colour, how it plays, how loud, where it starts
// and ends — a plate beside the grid, for the pad that was picked.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../state/booth/board/board_face.dart';
import '../../../state/booth/board/board_keys.dart';
import '../../../state/booth/board/pad_spec.dart';
import '../../feel.dart';
import '../../mag.dart';
import '../desk/console.dart';
import 'board_pad.dart';

class BoardEdit extends StatefulWidget {
  const BoardEdit({
    super.key,
    required this.board,
    required this.bank,
    required this.pad,
    required this.onClose,
    required this.onReplace,
    this.showKey = true,
  });

  /// The board: the desk's own, or a desk's on a screen that follows it.
  final BoardFace board;
  final int bank, pad;
  final VoidCallback onClose;

  /// Whether to show the desk's key for this pad (a phone has none).
  final bool showKey;

  /// Pick another sound for this pad, from the library.
  final VoidCallback onReplace;

  @override
  State<BoardEdit> createState() => _BoardEditState();
}

class _BoardEditState extends State<BoardEdit> {
  late final TextEditingController _name;
  Timer? _rename;

  PadSpec? get _spec => widget.board.pad(widget.bank, widget.pad);

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: _spec?.name ?? '');
  }

  @override
  void didUpdateWidget(covariant BoardEdit old) {
    super.didUpdateWidget(old);
    if (old.bank != widget.bank || old.pad != widget.pad) {
      _rename?.cancel();
      _name.text = _spec?.name ?? '';
    }
  }

  @override
  void dispose() {
    _rename?.cancel();
    _name.dispose();
    super.dispose();
  }

  Future<void> _set(PadSpec spec) => widget.board.setPad(widget.bank, widget.pad, spec);

  @override
  Widget build(BuildContext context) {
    final spec = _spec;
    if (spec == null) {
      return Plate(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_circle_outline, size: 22, color: Console.faint),
              const SizedBox(height: 8),
              Text('NOTHING HERE YET', style: Console.label(10, color: Console.quiet)),
              const SizedBox(height: 6),
              Text('Drop a sound on the pad, or pick one from the library.',
                  textAlign: TextAlign.center, style: Mag.typewriter(11, color: Console.quiet)),
              const SizedBox(height: 12),
              Pad(label: 'PICK A SOUND', colour: Console.ink, height: 30, onTap: widget.onReplace),
            ],
          ),
        ),
      );
    }
    final c = padColourOf(spec.colour, context);
    final sample = widget.board.library.byId(spec.sampleId);
    final peaks = widget.board.peaksOf(spec.sampleId);
    final length = sample?.length ?? const Duration(seconds: 1);
    final playing = widget.board.stateOf(widget.bank, widget.pad).sounding;

    return Plate(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Text('PAD ${widget.pad + 1} · BANK ${widget.board.doc.banks[widget.bank].name}',
                  style: Console.label(10, color: Console.ink)),
              const Spacer(),
              Pad(icon: Icons.close, width: 28, height: 26, colour: Console.ink, tooltip: 'Done', onTap: widget.onClose),
            ]),
            const SizedBox(height: 10),
            // The name, as the pad says it.
            TextField(
              controller: _name,
              style: Mag.typewriter(13, color: Console.ink, bold: true),
              textCapitalization: TextCapitalization.characters,
              maxLength: 24,
              decoration: InputDecoration(
                isDense: true,
                counterText: '',
                labelText: 'NAME',
                labelStyle: Console.label(9),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Console.line)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: c)),
              ),
              onChanged: (v) {
                _rename?.cancel();
                _rename = Timer(const Duration(milliseconds: 400), () {
                  final s = _spec;
                  if (s != null && s.name != v.trim()) unawaited(_set(s.copyWith(name: v.trim())));
                });
              },
            ),
            const SizedBox(height: 12),
            _row('COLOUR', Wrap(spacing: 6, children: [
              for (final k in PadColour.values)
                _Swatch(
                  colour: padColourOf(k, context),
                  on: k == spec.colour,
                  onTap: () {
                    feel(Feel.pick);
                    unawaited(_set(spec.copyWith(colour: k)));
                  },
                ),
            ])),
            const SizedBox(height: 10),
            _row('PLAYS', Row(children: [
              for (final m in PadMode.values) ...[
                Expanded(
                  child: Pad(
                    label: m.label.toUpperCase(),
                    height: 28,
                    lit: m == spec.mode,
                    colour: c,
                    tooltip: switch (m) {
                      PadMode.oneShot => 'Pressed, it plays through once; pressed again, it starts over',
                      PadMode.hold => 'Plays while held',
                      PadMode.toggle => 'Pressed, it plays; pressed again, it stops',
                      PadMode.loop => 'Round and round until pressed again',
                    },
                    onTap: () => unawaited(_set(spec.copyWith(mode: m))),
                  ),
                ),
                if (m != PadMode.values.last) const SizedBox(width: 4),
              ],
            ])),
            const SizedBox(height: 10),
            _row('STARTS', Row(children: [
              for (final q in Quantise.values) ...[
                Expanded(
                  child: Pad(
                    label: switch (q) {
                      Quantise.off => 'PRESSED',
                      Quantise.beat => 'ON THE BEAT',
                      Quantise.bar => 'ON THE BAR'
                    },
                    height: 26,
                    lit: q == spec.quantise,
                    colour: c,
                    tooltip: switch (q) {
                      Quantise.off => 'The moment it is pressed',
                      Quantise.beat => "Waits for the master's next beat",
                      Quantise.bar => "Waits for the master's next bar",
                    },
                    onTap: () => unawaited(_set(spec.copyWith(quantise: q))),
                  ),
                ),
                if (q != Quantise.values.last) const SizedBox(width: 4),
              ],
            ])),
            const SizedBox(height: 10),
            _row('CHOKE GROUP · ONE OF IT AT A TIME', Row(children: [
              for (final g in [0, 1, 2, 3, 4]) ...[
                Expanded(
                  child: Pad(
                    label: g == 0 ? 'NONE' : '$g',
                    height: 26,
                    lit: g == spec.choke,
                    colour: c,
                    tooltip: g == 0 ? 'Sounds over anything' : 'Pressing this stops the others of group $g',
                    onTap: () => unawaited(_set(spec.copyWith(choke: g))),
                  ),
                ),
                if (g != 4) const SizedBox(width: 3),
              ],
            ])),
            const SizedBox(height: 12),
            Row(children: [
              Knob(
                value: spec.gain,
                min: 0,
                max: 1.5,
                rest: 1,
                bipolar: false,
                size: 42,
                colour: c,
                label: 'GAIN',
                tooltip: 'This pad\'s own level · double-click for as it is',
                onChanged: (v) => unawaited(_set(spec.copyWith(gain: v))),
              ),
              const SizedBox(width: 16),
              Knob(
                value: spec.duck,
                min: 0,
                max: 1,
                rest: 0,
                bipolar: false,
                size: 42,
                colour: c,
                label: 'DUCK',
                tooltip: 'How far the decks dip while this sounds',
                onChanged: (v) => unawaited(_set(spec.copyWith(duck: v))),
              ),
              const Spacer(),
              if (widget.showKey)
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('KEY', style: Console.label(8)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
                  decoration: BoxDecoration(
                    color: Console.raised,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Console.line),
                  ),
                  child: Text(BoardKeys.capFor(widget.pad), style: Mag.typewriter(11, color: Console.ink, bold: true)),
                ),
              ]),
            ]),
            const SizedBox(height: 12),
            _row(
              'TRIM',
              SizedBox(
                height: 56,
                child: _TrimStrip(
                  peaks: peaks,
                  length: length,
                  colour: c,
                  trimIn: spec.trimIn,
                  trimOut: spec.trimOut ?? length,
                  onChanged: (i, o) => unawaited(_set(spec.copyWith(
                    trimIn: i,
                    trimOut: o,
                    clearTrimOut: o >= length - const Duration(milliseconds: 5),
                  ))),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(children: [
              Text(_ms(spec.trimIn), style: Mag.typewriter(10, color: Console.quiet)),
              const Spacer(),
              Text('${sample?.name ?? '?'} · ${_ms(length)}', style: Mag.typewriter(10, color: Console.quiet)),
              const Spacer(),
              Text(_ms(spec.trimOut ?? length), style: Mag.typewriter(10, color: Console.quiet)),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Pad(
                icon: playing ? Icons.stop : Icons.play_arrow,
                label: playing ? 'STOP' : 'LISTEN',
                width: 92,
                height: 30,
                colour: c,
                lit: playing,
                onTap: () => playing
                    ? unawaited(widget.board.quiet(widget.bank, widget.pad))
                    : unawaited(widget.board.listen(widget.bank, widget.pad)),
              ),
              const Spacer(),
              Pad(label: 'REPLACE', height: 30, colour: Console.ink, onTap: widget.onReplace),
              const SizedBox(width: 6),
              Pad(
                label: 'CLEAR',
                height: 30,
                colour: Console.ink,
                onTap: () {
                  feel(Feel.warn);
                  unawaited(widget.board.setPad(widget.bank, widget.pad, null));
                },
              ),
            ]),
          ],
        ),
      ),
    );
  }

  static String _ms(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(2)} s';

  Widget _row(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: Console.label(8)),
          const SizedBox(height: 4),
          child,
        ],
      );
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.colour, required this.on, required this.onTap});
  final Color colour;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: colour,
            shape: BoxShape.circle,
            border: Border.all(color: on ? Console.ink : Console.line, width: on ? 2 : 1),
          ),
        ),
      );
}

/// The sample's shape with two handles over it: where the pad starts and where it
/// stops. Drag either; the nearer one follows the pointer.
class _TrimStrip extends StatefulWidget {
  const _TrimStrip({
    required this.peaks,
    required this.length,
    required this.colour,
    required this.trimIn,
    required this.trimOut,
    required this.onChanged,
  });

  final Float32List? peaks;
  final Duration length, trimIn, trimOut;
  final Color colour;
  final void Function(Duration trimIn, Duration trimOut) onChanged;

  @override
  State<_TrimStrip> createState() => _TrimStripState();
}

class _TrimStripState extends State<_TrimStrip> {
  bool? _draggingIn;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth;
        double xOf(Duration d) => w * (d.inMicroseconds / widget.length.inMicroseconds).clamp(0.0, 1.0);
        Duration dOf(double x) => Duration(
            microseconds: (widget.length.inMicroseconds * (x / w).clamp(0.0, 1.0)).round());
        void at(double x) {
          final min = const Duration(milliseconds: 20);
          if (_draggingIn ?? true) {
            var i = dOf(x);
            if (i > widget.trimOut - min) i = widget.trimOut - min;
            widget.onChanged(i < Duration.zero ? Duration.zero : i, widget.trimOut);
          } else {
            var o = dOf(x);
            if (o < widget.trimIn + min) o = widget.trimIn + min;
            widget.onChanged(widget.trimIn, o > widget.length ? widget.length : o);
          }
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) {
            final x = d.localPosition.dx;
            _draggingIn = (x - xOf(widget.trimIn)).abs() <= (x - xOf(widget.trimOut)).abs();
            at(x);
          },
          onHorizontalDragUpdate: (d) => at(d.localPosition.dx),
          onHorizontalDragEnd: (_) => _draggingIn = null,
          child: CustomPaint(
            size: Size(w, c.maxHeight),
            painter: _TrimPainter(
              peaks: widget.peaks,
              colour: widget.colour,
              inT: xOf(widget.trimIn) / w,
              outT: xOf(widget.trimOut) / w,
            ),
          ),
        );
      });
}

class _TrimPainter extends CustomPainter {
  _TrimPainter({required this.peaks, required this.colour, required this.inT, required this.outT});
  final Float32List? peaks;
  final Color colour;
  final double inT, outT;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4));
    canvas.drawRRect(r, Paint()..color = Console.ground);
    final p = peaks;
    final mid = size.height / 2;
    if (p != null && p.isNotEmpty) {
      final path = Path();
      for (var i = 0; i < p.length; i++) {
        final x = size.width * i / (p.length - 1);
        path.moveTo(x, mid - (size.height / 2 - 4) * p[i]);
        path.lineTo(x, mid + (size.height / 2 - 4) * p[i]);
      }
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = size.width / p.length * 0.7
            ..color = colour.withValues(alpha: 0.7));
    } else {
      canvas.drawLine(Offset(0, mid), Offset(size.width, mid), Paint()..color = Console.line);
    }
    // Outside the trim, shaded away.
    final shade = Paint()..color = Console.ground.withValues(alpha: 0.72);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width * inT, size.height), shade);
    canvas.drawRect(Rect.fromLTWH(size.width * outT, 0, size.width * (1 - outT), size.height), shade);
    for (final t in [inT, outT]) {
      final x = size.width * t;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), Paint()..color = Console.ink..strokeWidth = 2);
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, size.height / 2), width: 8, height: 16),
              const Radius.circular(2)),
          Paint()..color = Console.ink);
    }
  }

  @override
  bool shouldRepaint(_TrimPainter o) => o.peaks != peaks || o.colour != colour || o.inT != inT || o.outT != outT;
}
