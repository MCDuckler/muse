// The player in the column beside the page, at the sizes the column actually gives it.
//
// The panel asks for a height (DeskNowPlaying.wanted) and the column hands it one, and
// the two have to agree: everything in it — the title, the record, the bar, the
// transport, the song's buttons, the volume — has to fit in what it asked for. Where
// they disagree the panel overflows, which is a black and yellow bar across the bottom
// of the player in a debug build and a row of controls cut off in a release one.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/player.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/desk_dock.dart';
import 'package:muse/src/ui/now_playing.dart';

import 'fake_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('com.ryanheise.audio_session'), (c) async => null);

  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    JustAudioPlatform.instance = FakeJustAudio();
    app = AppState()..api = ApiClient(baseUrl: 'http://example.invalid');
    app.player = PlayerService(app.api);
    await app.player!.init();
    await app.player!.loadQueue(Queue.fromJson({
      'id': 1,
      'name': 'Mine',
      'cursor_index': 0,
      'position_ms': 0,
      'rev': 1,
      'items': [
        {
          'id': 1,
          'title': 'A record with a name long enough to take two lines of it',
          'artists': ['Somebody With A Long Name Too'],
          'duration_ms': 180000,
          'state': 'ready',
        }
      ],
    }));
  });

  tearDown(() async => app.player?.dispose());

  Future<void> panel(WidgetTester tester, double width, double height) async {
    tester.view.physicalSize = Size(width + 40, height + 40);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: height,
              child: const DeskNowPlaying(),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('it fits in the height it asks for, at every width the column allows',
      (tester) async {
    // The column is dragged between its floor and 640 wide, so the panel has to hold
    // at both ends of that and in the middle. The floor is asked for by name, so that
    // moving it without checking the player still fits fails here.
    final spilled = <String>[];
    for (final width in [DeskDock.minWidth, 420.0, 520.0, 640.0]) {
      await panel(tester, width, DeskNowPlaying.wanted(width));
      final e = tester.takeException();
      if (e != null) spilled.add('$width: $e');
    }
    expect(spilled, isEmpty, reason: spilled.join('\n'));
  });

  testWidgets('and in a shorter column than it asked for', (tester) async {
    // A short window gives it less than it wants; it is allowed to shrink the record
    // or to scroll, and not to spill.
    final spilled = <String>[];
    for (final height in [300.0, 420.0, 560.0]) {
      await panel(tester, 420, height);
      final e = tester.takeException();
      if (e != null) spilled.add('${height}px: $e');
    }
    expect(spilled, isEmpty, reason: spilled.join('\n'));
  });
}
