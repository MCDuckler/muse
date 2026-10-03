// The board: a page of the booth beside the decks, slid to and back.
//
// Sixteen pads in four rows with the bank row above them, the board's own fader
// beside them, a pad's settings when one is picked, and the library down the right
// — drawn from a BoardFace, which is the Soundboard itself on the desk that makes
// the sound and a copy of it on a phone or in a window of its own.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../state/booth/board/board_face.dart';
import '../../../state/booth/board/board_keys.dart';
import '../../../state/booth/board/pad_spec.dart';
import '../../../state/booth/board/samples.dart';
import '../../../state/booth/board/soundboard.dart';
import '../../../state/booth/booth.dart';
import '../../dialogs.dart';
import '../../feel.dart';
import '../../mag.dart';
import '../desk/console.dart';
import '../desk/console_log.dart';
import 'board_edit.dart';
import 'board_library.dart';
import 'board_pad.dart';

/// Bumped by the B key: the room slides to the board, or back.
final boardToggles = ValueNotifier<int>(0);

class BoardRoom extends StatefulWidget {
  const BoardRoom({super.key, required this.face, this.booth, this.narrow = false, this.onPopOut});

  final BoardFace face;

  /// The board in a window of its own, where a desk can: null elsewhere.
  final VoidCallback? onPopOut;

  /// The booth, where the board is this device's own: the log and the library
  /// come with it. Null on a phone showing a desk's board.
  final Booth? booth;

  /// A phone: four across, two rows at a time, no side columns.
  final bool narrow;

  @override
  State<BoardRoom> createState() => _BoardRoomState();
}

class _BoardRoomState extends State<BoardRoom> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _now = ValueNotifier(DateTime.now());
  (int, int)? _selected;
  (int, int)? _picking;
  bool _editing = false;

  BoardFace get _face => widget.face;
  Soundboard? get _own => _face is Soundboard ? _face as Soundboard : null;

  @override
  void initState() {
    super.initState();
    _face.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(covariant BoardRoom old) {
    super.didUpdateWidget(old);
    if (!identical(old.face, widget.face)) {
      old.face.removeListener(_changed);
      widget.face.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _face.removeListener(_changed);
    _ticker.dispose();
    _now.dispose();
    super.dispose();
  }

  /// The clock runs while anything sounds or waits, and rests otherwise.
  void _changed() {
    if (!mounted) return;
    var moving = _face.anySounding;
    if (!moving) {
      for (var p = 0; p < Bank.size && !moving; p++) {
        moving = _face.stateOf(_face.bank, p).waiting;
      }
    }
    if (moving && !_ticker.isActive) {
      _ticker.start();
    } else if (!moving && _ticker.isActive) {
      _ticker.stop();
      _now.value = DateTime.now();
    }
    setState(() {});
  }

  void _tick(Duration _) => _now.value = DateTime.now();

  Future<void> _pick(Sample s) async {
    final at = _picking ?? _selected;
    if (at == null) return;
    final own = _own;
    if (own == null) return;
    final was = own.pad(at.$1, at.$2);
    await own.setPad(at.$1, at.$2, was == null ? padFor(s) : was.copyWith(sampleId: s.id));
    setState(() {
      _picking = null;
      _selected = at;
    });
  }

  @override
  Widget build(BuildContext context) {
    final own = _own;
    final editable = own != null && _face.editable;
    final selected = _selected;
    if (widget.narrow) return _narrow(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              BoothPanel(child: _bankRow(context, editable)),
              const SizedBox(height: 10),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: BoothPanel(child: Plate(padding: const EdgeInsets.all(10), child: _grid()))),
                    const SizedBox(width: 10),
                    SizedBox(width: 56, child: BoothPanel(child: _level())),
                    if (editable && selected != null) ...[
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 340,
                        child: BoothPanel(
                          child: BoardEdit(
                            board: own,
                            bank: selected.$1,
                            pad: selected.$2,
                            onClose: () => setState(() {
                              _selected = null;
                              _picking = null;
                            }),
                            onReplace: () => setState(() => _picking = selected),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        if (own != null && widget.booth != null) ...[
          const SizedBox(width: 10),
          SizedBox(
            width: 300,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 3,
                  child: BoothPanel(
                    child: BoardLibrary(board: own, booth: widget.booth, forPad: _picking, onPicked: (s) => unawaited(_pick(s))),
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(flex: 2, child: BoothPanel(child: ConsoleLog(booth: widget.booth!))),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// A phone: the bank row, the pads, the fader across, and a picked pad's
  /// settings under them; the library opens over the room when a pad asks.
  Widget _narrow(BuildContext context) {
    final own = _own;
    final editable = own != null && _face.editable;
    final selected = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _bankRow(context, editable, narrow: true),
        const SizedBox(height: 8),
        Plate(padding: const EdgeInsets.all(8), child: _grid(rows: 4)),
        const SizedBox(height: 8),
        if (editable && selected != null) ...[
          SizedBox(
            height: 520,
            child: BoardEdit(
              board: own,
              bank: selected.$1,
              pad: selected.$2,
              showKey: false,
              onClose: () => setState(() {
                _selected = null;
                _picking = null;
              }),
              onReplace: () => unawaited(_librarySheet(context, selected)),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Plate(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(children: [
            Text('LEVEL', style: Console.label(8)),
            const SizedBox(width: 10),
            Expanded(
              child: Slider(
                value: _face.doc.level,
                onChanged: (v) => unawaited(_face.setLevel(v)),
                activeColor: Console.ink,
                inactiveColor: Console.line,
              ),
            ),
          ]),
        ),
      ],
    );
  }

  /// The library over the room, for [at]: a tapped sound goes there.
  Future<void> _librarySheet(BuildContext context, (int, int) at) async {
    final own = _own;
    if (own == null) return;
    setState(() => _picking = at);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Console.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (sheet) => SizedBox(
        height: MediaQuery.sizeOf(sheet).height * 0.7,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
          child: BoardLibrary(
            board: own,
            booth: widget.booth,
            forPad: at,
            onPicked: (s) {
              Navigator.of(sheet).pop();
              unawaited(_pick(s));
            },
          ),
        ),
      ),
    );
    if (mounted) setState(() => _picking = null);
  }

  Widget _bankRow(BuildContext context, bool editable, {bool narrow = false}) {
    final accent = Theme.of(context).colorScheme.primary;
    final doc = _face.doc;
    return Plate(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Row(
        children: [
          if (!narrow) ...[
            Text('BANK', style: Console.label(9)),
            const SizedBox(width: 8),
          ],
          for (var i = 0; i < doc.banks.length; i++) ...[
            _BankPad(
              name: doc.banks[i].name,
              on: i == _face.bank,
              sounding: _soundingOn(i),
              narrow: narrow,
              onTap: () => unawaited(_face.showBank(i)),
              onRename: editable ? () => _rename(context, i) : null,
            ),
            const SizedBox(width: 4),
          ],
          if (editable) ...[
            const SizedBox(width: 8),
            Pad(
              icon: Icons.edit_outlined,
              label: narrow ? null : 'EDIT',
              height: 28,
              lit: _editing,
              colour: Console.ink,
              tooltip: _editing ? 'Pads play again' : 'Pressing a pad opens its settings instead of playing it',
              onTap: () => setState(() => _editing = !_editing),
            ),
            if (!narrow) ...[
              const SizedBox(width: 4),
              _PinMenu(board: _own!, bank: _face.bank),
            ],
          ],
          const Spacer(),
          if (!narrow) ...[
            Text(BoardKeys.caption, style: Mag.typewriter(10, color: Console.faint)),
            const SizedBox(width: 12),
          ],
          if (widget.onPopOut != null) ...[
            Pad(
              icon: Icons.open_in_new,
              width: 34,
              height: 28,
              colour: Console.ink,
              tooltip: 'The board in a window of its own (⌥B)',
              onTap: widget.onPopOut,
            ),
            const SizedBox(width: 6),
          ],
          Pad(
            icon: Icons.stop,
            label: narrow ? null : 'STOP ALL',
            height: 28,
            width: narrow ? 40 : 100,
            lit: _face.anySounding,
            colour: _face.anySounding ? accent : Console.ink,
            tooltip: 'Every pad quiet (KP 0)',
            onTap: () {
              feel(Feel.warn);
              unawaited(_face.stopAll());
            },
          ),
        ],
      ),
    );
  }

  bool _soundingOn(int bank) {
    for (var p = 0; p < Bank.size; p++) {
      if (_face.stateOf(bank, p).sounding) return true;
    }
    return false;
  }

  Future<void> _rename(BuildContext context, int i) async {
    final own = _own;
    if (own == null) return;
    final name = await promptForName(context, 'Name bank ${BoardDoc.bankNames[i]}', own.doc.banks[i].name);
    if (name == null) return;
    await own.renameBank(i, name);
  }

  Widget _level() {
    final doc = _face.doc;
    return Plate(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
      child: Column(
        children: [
          Text('LEVEL', style: Console.label(8)),
          const SizedBox(height: 6),
          Expanded(
            child: VFader(
              value: doc.level,
              colour: Console.ink,
              width: 30,
              onChanged: (v) => unawaited(_face.setLevel(v)),
              onDoubleTap: () => unawaited(_face.setLevel(0.8)),
            ),
          ),
          const SizedBox(height: 6),
          Text('${(doc.level * 100).round()}', style: Mag.typewriter(10, color: Console.quiet)),
        ],
      ),
    );
  }

  Widget _grid({int rows = 4}) {
    final bank = _face.bank;
    final own = _own;
    final editable = own != null && _face.editable;
    return LayoutBuilder(builder: (context, c) {
      const gap = 8.0;
      final side = ((c.maxWidth - gap * (Bank.across - 1)) / Bank.across)
          .clamp(40.0, (c.maxHeight - gap * (rows - 1)) / rows)
          .toDouble();
      return Center(
        child: SizedBox(
          width: side * Bank.across + gap * (Bank.across - 1),
          height: side * rows + gap * (rows - 1),
          child: Column(
            children: [
              for (var r = 0; r < rows; r++) ...[
                if (r > 0) const SizedBox(height: gap),
                Expanded(
                  child: Row(
                    children: [
                      for (var col = 0; col < Bank.across; col++) ...[
                        if (col > 0) const SizedBox(width: gap),
                        Expanded(child: _padAt(bank, r * Bank.across + col, editable)),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    });
  }

  Widget _padAt(int bank, int i, bool editable) {
    final spec = _face.pad(bank, i);
    final selected = _selected == (bank, i);
    Widget pad(bool dropping) => BoardPad(
          spec: spec,
          state: _face.stateOf(bank, i),
          now: _now,
          peaks: spec == null ? null : _face.peaksOf(spec.sampleId),
          keyCap: widget.narrow ? null : BoardKeys.capFor(i),
          selected: selected,
          editing: _editing,
          dropping: dropping,
          onDown: () => unawaited(_face.press(bank, i)),
          onUp: () => unawaited(_face.release(bank, i)),
          onEdit: editable
              ? () {
                  setState(() {
                    _selected = (bank, i);
                    _picking = spec == null ? (bank, i) : null;
                  });
                  if (widget.narrow && spec == null) unawaited(_librarySheet(context, (bank, i)));
                }
              : null,
        );
    if (!editable) return pad(false);
    return DragTarget<Sample>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) {
        feel(Feel.commit);
        unawaited(_own!.setPad(bank, i, spec == null ? padFor(d.data) : spec.copyWith(sampleId: d.data.id)));
        setState(() => _selected = (bank, i));
      },
      builder: (context, candidates, _) => pad(candidates.isNotEmpty),
    );
  }
}

class _BankPad extends StatelessWidget {
  const _BankPad(
      {required this.name, required this.on, required this.sounding, required this.onTap, this.onRename, this.narrow = false});
  final String name;
  final bool on, sounding, narrow;
  final VoidCallback onTap;
  final VoidCallback? onRename;

  @override
  Widget build(BuildContext context) => Stack(
        clipBehavior: Clip.none,
        children: [
          Pad(
            label: narrow && name.length > 2 ? name.substring(0, 2) : name,
            height: 28,
            width: name.length <= 2 || narrow ? (narrow ? 32 : 36) : null,
            lit: on,
            colour: Console.ink,
            tooltip: onRename == null ? null : 'Bank $name · right-click to name it',
            onTap: onTap,
            onLongPress: onRename,
          ),
          if (sounding)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle),
              ),
            ),
        ],
      );
}

enum TabSide { left, right }

/// The tab at the room's edge: BOARD ▸ beside the decks, ◂ DECKS beside the board.
/// Lit in the colour of the pad sounding, so the board is seen from the decks.
class BoardTab extends StatefulWidget {
  const BoardTab({super.key, required this.side, required this.label, required this.onTap, this.face});
  final TabSide side;
  final String label;
  final VoidCallback onTap;

  /// The board, for the light; null on the board's own side.
  final BoardFace? face;

  @override
  State<BoardTab> createState() => _BoardTabState();
}

class _BoardTabState extends State<BoardTab> {
  bool _over = false;

  @override
  void initState() {
    super.initState();
    widget.face?.addListener(_changed);
  }

  @override
  void dispose() {
    widget.face?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final face = widget.face;
    final lit = face != null && face.anySounding;
    final c = lit ? padColourOf(face.lastFired?.colour ?? PadColour.white, context) : null;
    final right = widget.side == TabSide.right;
    final text = right ? '${widget.label} ▸' : '◂ ${widget.label}';
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _over = true),
      onExit: (_) => setState(() => _over = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          feel(Feel.pick);
          widget.onTap();
        },
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if ((right && v < -100) || (!right && v > 100)) widget.onTap();
        },
        child: Tooltip(
          message: right ? 'The board (B, or scroll sideways)' : 'The decks (B, or scroll sideways)',
          waitDuration: const Duration(milliseconds: 600),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 22,
            margin: EdgeInsets.only(left: right ? 6 : 0, right: right ? 0 : 6, bottom: 0),
            decoration: BoxDecoration(
              color: lit ? c!.withValues(alpha: 0.18) : (_over ? Console.hover : Console.raised),
              borderRadius: BorderRadius.horizontal(
                left: Radius.circular(right ? 6 : 0),
                right: Radius.circular(right ? 0 : 6),
              ),
              border: Border.all(color: lit ? c! : Console.line),
            ),
            child: Center(
              child: RotatedBox(
                quarterTurns: right ? 1 : 3,
                child: Text(text, style: Console.label(9, color: lit ? c : (_over ? Console.ink : Console.quiet))),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The bar's light for the board: the pad sounding, in its colour; pressed, the
/// room slides to the board.
class BoardLight extends StatefulWidget {
  const BoardLight({super.key, required this.face, required this.onTap});
  final BoardFace face;
  final VoidCallback onTap;

  @override
  State<BoardLight> createState() => _BoardLightState();
}

class _BoardLightState extends State<BoardLight> {
  @override
  void initState() {
    super.initState();
    widget.face.addListener(_changed);
  }

  @override
  void dispose() {
    widget.face.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.face.anySounding;
    final c = on ? padColourOf(widget.face.lastFired?.colour ?? PadColour.white, context) : Console.quiet;
    return IconButton(
      icon: Icon(Icons.grid_view_rounded, color: c),
      tooltip: on ? 'The board · ${widget.face.lastFired?.name ?? ''}' : 'The board (B)',
      onPressed: widget.onTap,
    );
  }
}

/// Pin a row of the shown bank under the decks, or let it go.
class _PinMenu extends StatelessWidget {
  const _PinMenu({required this.board, required this.bank});
  final Soundboard board;
  final int bank;

  @override
  Widget build(BuildContext context) {
    final strip = board.doc.strip;
    final pinnedHere = strip != null && strip.bank == bank;
    return PopupMenuButton<int>(
      tooltip: 'A row of pads under the decks',
      color: Console.raised,
      position: PopupMenuPosition.under,
      onSelected: (row) {
        feel(Feel.pick);
        unawaited(board.setStrip(row < 0 ? null : StripSpec(bank: bank, row: row)));
      },
      itemBuilder: (context) => [
        for (var r = 0; r < Bank.size ~/ Bank.across; r++)
          PopupMenuItem<int>(
            value: r,
            height: 34,
            child: Text('PIN ROW ${r + 1} UNDER THE DECKS',
                style: Console.label(10, color: pinnedHere && strip.row == r ? Theme.of(context).colorScheme.primary : Console.ink)),
          ),
        if (strip != null) ...[
          const PopupMenuDivider(),
          PopupMenuItem<int>(value: -1, height: 34, child: Text('UNPIN', style: Console.label(10, color: Console.ink))),
        ],
      ],
      child: Pad(
        icon: Icons.push_pin_outlined,
        label: pinnedHere ? 'ROW ${strip.row + 1} PINNED' : 'PIN',
        height: 28,
        lit: pinnedHere,
        colour: Console.ink,
        onTap: null,
      ),
    );
  }
}

/// The pinned row: eight pads of one bank in a strip under the decks, with the
/// board's level beside them — the board without leaving the records.
class BoardStrip extends StatefulWidget {
  const BoardStrip({super.key, required this.face, required this.onBoard});
  final BoardFace face;
  final VoidCallback onBoard;

  static const height = 46.0;

  @override
  State<BoardStrip> createState() => _BoardStripState();
}

class _BoardStripState extends State<BoardStrip> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => _now.value = DateTime.now());
  final _now = ValueNotifier(DateTime.now());

  @override
  void initState() {
    super.initState();
    widget.face.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    widget.face.removeListener(_changed);
    _ticker.dispose();
    _now.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final moving = widget.face.anySounding;
    if (moving && !_ticker.isActive) {
      _ticker.start();
    } else if (!moving && _ticker.isActive) {
      _ticker.stop();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final face = widget.face;
    final strip = face.doc.strip;
    if (strip == null) return const SizedBox.shrink();
    final bank = strip.bank.clamp(0, face.doc.banks.length - 1);
    final from = strip.row * Bank.across;
    return Plate(
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Console.raised,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Console.line),
            ),
            child: Text(face.doc.banks[bank].name, style: Console.label(9, color: Console.ink)),
          ),
          const SizedBox(width: 8),
          for (var i = 0; i < Bank.across * 2; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              child: Builder(builder: (context) {
                final p = from + i;
                if (p >= Bank.size) return const SizedBox.shrink();
                final spec = face.pad(bank, p);
                return BoardPad(
                  spec: spec,
                  state: face.stateOf(bank, p),
                  now: _now,
                  compact: true,
                  onDown: () => unawaited(face.press(bank, p)),
                  onUp: () => unawaited(face.release(bank, p)),
                );
              }),
            ),
          ],
          const SizedBox(width: 10),
          SizedBox(
            width: 90,
            child: Slider(
              value: face.doc.level,
              onChanged: (v) => unawaited(face.setLevel(v)),
              activeColor: Console.ink,
              inactiveColor: Console.line,
              padding: EdgeInsets.zero,
            ),
          ),
          const SizedBox(width: 4),
          Pad(
            icon: Icons.grid_view_rounded,
            width: 34,
            height: 30,
            colour: Console.ink,
            tooltip: 'The board (B)',
            onTap: widget.onBoard,
          ),
        ],
      ),
    );
  }
}
