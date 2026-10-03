// The board in a window of its own: this program started again with `--board`
// and the desk's own address, showing nothing but the board, linked to the desk
// the way a phone is — over the loopback.
//
// A second process rather than a second window of the first: Flutter's own
// windowing is experimental, and the plugins the desk uses for its window and its
// tray assume there is one. A process that is exactly the phone's remote, pointed
// at 127.0.0.1, is one code path and no plugin surprises.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../../api/models.dart';
import '../../../state/app_state.dart';
import '../../../state/booth/board/remote_board.dart';
import '../../../state/booth/board/remote_link_none.dart' if (dart.library.io) '../../../state/booth/board/remote_link_io.dart' as lan;
import '../../theme.dart';
import 'remote_board_page.dart';

/// The argument that makes this program a board window: `--board <ws url>`.
const boardWindowFlag = '--board';

/// The url after [boardWindowFlag] in [args], or null.
String? boardWindowUrl(List<String> args) {
  final i = args.indexOf(boardWindowFlag);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

/// Before the first frame of a board window: its own title and size.
Future<void> readyTheBoardWindow() async {
  if (kIsWeb) return;
  try {
    await windowManager.ensureInitialized();
    await windowManager.setTitle('WetOwl · Board');
    await windowManager.setMinimumSize(const Size(420, 480));
    await windowManager.setSize(const Size(600, 680));
    await windowManager.show();
  } catch (e) {
    debugPrint('board window: $e');
  }
}

class BoardWindowApp extends StatefulWidget {
  const BoardWindowApp({super.key, required this.url});
  final String url;

  @override
  State<BoardWindowApp> createState() => _BoardWindowAppState();
}

class _BoardWindowAppState extends State<BoardWindowApp> {
  RemoteBoard? _remote;
  String? _trouble;

  @override
  void initState() {
    super.initState();
    unawaited(_connect());
  }

  Future<void> _connect() async {
    final link = await lan.connectLanUrl(widget.url, name: 'Board window');
    if (!mounted) return;
    if (link == null) {
      setState(() => _trouble = 'The booth did not answer.');
      return;
    }
    setState(() {
      _remote = RemoteBoard.over(
        const DeviceInfo(id: 0, name: 'This desk', live: true),
        link,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final remote = _remote;
    // A small AppState, for the palette and nothing else: no login, no player.
    return ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp(
        title: 'WetOwl · Board',
        debugShowCheckedModeBanner: false,
        theme: MuseTheme.dark(),
        home: remote == null
            ? Scaffold(
                backgroundColor: const Color(0xFF0B0B0D),
                body: Center(
                  child: Text(_trouble ?? 'Linking to the booth…',
                      style: const TextStyle(color: Color(0xFF8E8A82), fontSize: 13)),
                ),
              )
            : RemoteBoardPage(remote: remote, satellite: true),
      ),
    );
  }
}
