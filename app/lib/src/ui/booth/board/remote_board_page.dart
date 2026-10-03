// A desk's board on this screen: the whole page, with the link's state in its bar.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../../api/models.dart';
import '../../../state/app_state.dart';
import '../../../state/booth/board/remote_board.dart';
import '../../../state/device_name.dart';
import '../../mag.dart';
import '../../snack.dart';
import '../../theme.dart';
import '../../widths.dart';
import '../desk/console.dart';
import '../desk/console_room.dart' show BoothMark;
import 'board_room.dart';

/// The desks of this account whose booth offers a board right now.
List<DeviceInfo> desksWithABoard(AppState app) =>
    [for (final d in app.devices) if (!d.isThis && d.live && d.boardLink != null) d];

/// Opens [desk]'s board on this screen.
Future<void> openRemoteBoard(BuildContext context, DeviceInfo desk) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final remote = await RemoteBoard.connect(
    desk,
    myName: deviceName(),
    relay: () => RelayLink(deskId: desk.id, post: app.api.boardEvents, states: app.boardStates),
    // Signed in here too: the sounds to pick from are asked of the server, not the desk.
    api: app.api,
  );
  if (remote == null) {
    messenger.say(snack(Text('${desk.name} could not be reached')));
    return;
  }
  if (!context.mounted) {
    remote.dispose();
    return;
  }
  await Navigator.of(context, rootNavigator: true)
      .push(MaterialPageRoute(builder: (_) => RemoteBoardPage(remote: remote)));
}

class RemoteBoardPage extends StatefulWidget {
  const RemoteBoardPage({super.key, required this.remote, this.satellite = false});
  final RemoteBoard remote;

  /// The board's own window on the desk: no way back, a pin to keep it on top,
  /// and the window goes when the booth does.
  final bool satellite;

  @override
  State<RemoteBoardPage> createState() => _RemoteBoardPageState();
}

class _RemoteBoardPageState extends State<RemoteBoardPage> {
  RemoteBoard get _r => widget.remote;

  @override
  void initState() {
    super.initState();
    _r.addListener(_changed);
  }

  @override
  void dispose() {
    _r.removeListener(_changed);
    _r.dispose();
    super.dispose();
  }

  bool _onTop = false;

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (widget.satellite && !_r.linked) {
      // The booth closed: this window has nothing to show. A moment to read it, then out.
      Future<void>.delayed(const Duration(seconds: 2), () {
        if (!kIsWeb) unawaited(windowManager.close());
      });
    }
  }

  Future<void> _pin() async {
    _onTop = !_onTop;
    setState(() {});
    try {
      await windowManager.setAlwaysOnTop(_onTop);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.select<AppState, Palette>((a) => a.palette);
    // The desk's look, not this screen's: the two should match across the room.
    Console.tones = _r.light ? ConsoleTones.lit : ConsoleTones.dark;
    final compact = Width.of(context) == Width.compact;
    return Theme(
      data: _r.light ? MuseTheme.light(palette) : MuseTheme.dark(palette),
      child: Scaffold(
        backgroundColor: Console.ground,
        body: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 52,
                child: Row(children: [
                  if (!widget.satellite)
                    IconButton(
                      icon: Icon(Icons.arrow_back, color: Console.quiet),
                      tooltip: 'Back',
                      onPressed: () => Navigator.of(context).maybePop(),
                    )
                  else
                    const SizedBox(width: 10),
                  BoothMark(on: _r.anySounding),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(_r.desk.name.toUpperCase(),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: Console.label(10, color: Console.quiet)),
                  ),
                  const Spacer(),
                  _LinkChip(remote: _r),
                  if (widget.satellite)
                    IconButton(
                      icon: Icon(_onTop ? Icons.push_pin : Icons.push_pin_outlined,
                          color: _onTop ? Console.ink : Console.quiet),
                      tooltip: _onTop ? 'Let other windows over it' : 'Keep this window on top',
                      onPressed: () => unawaited(_pin()),
                    ),
                  const SizedBox(width: 8),
                ]),
              ),
              Expanded(
                child: !_r.ready
                    ? Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Console.quiet),
                          ),
                          const SizedBox(height: 14),
                          Text(_r.linked ? 'ASKING ${_r.desk.name.toUpperCase()} FOR ITS BOARD' : 'THE LINK DROPPED',
                              style: Console.label(10, color: Console.quiet)),
                        ]),
                      )
                    : compact
                        ? ListView(
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                            children: [BoardRoom(face: _r, narrow: true)],
                          )
                        : Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                            child: BoardRoom(face: _r),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// LAN · 8 ms, or RELAY · 180 ms — and a red dot when the wire dropped.
class _LinkChip extends StatelessWidget {
  const _LinkChip({required this.remote});
  final RemoteBoard remote;

  @override
  Widget build(BuildContext context) {
    final rtt = remote.rtt;
    final dropped = !remote.linked;
    final c = dropped
        ? Console.a
        : remote.kind == 'LAN'
            ? Theme.of(context).colorScheme.primary
            : Console.quiet;
    final words = dropped
        ? 'DROPPED'
        : '${remote.kind}${rtt == null ? '' : ' · ${rtt.inMilliseconds} ms'}';
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 9, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(words, style: Mag.typewriter(10, color: c, bold: true)),
      ]),
    );
  }
}

/// A button for the bar: the desks whose boards this screen could play, when there
/// are any. One desk opens straight away; several ask which.
class RemoteBoardButton extends StatelessWidget {
  const RemoteBoardButton({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final desks = context.select<AppState, List<DeviceInfo>>(desksWithABoard);
    if (desks.isEmpty) return const SizedBox.shrink();
    if (desks.length == 1) {
      return IconButton(
        icon: Icon(Icons.cast_connected_outlined, color: Theme.of(context).colorScheme.primary),
        tooltip: 'Play the board on ${desks.single.name}',
        onPressed: () => unawaited(openRemoteBoard(context, desks.single)),
      );
    }
    return PopupMenuButton<DeviceInfo>(
      icon: Icon(Icons.cast_connected_outlined, color: Theme.of(context).colorScheme.primary),
      tooltip: 'Play a desk\'s board',
      onSelected: (d) => unawaited(openRemoteBoard(context, d)),
      itemBuilder: (_) => [
        for (final d in desks) PopupMenuItem(value: d, child: Text('The board on ${d.name}')),
      ],
    );
  }
}
