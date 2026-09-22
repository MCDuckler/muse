// The row answers for itself.
//
// Only the queue used to know which song was playing; every other list drew the
// song being played like any other. And a tap did nothing visible until the player
// had written the queue and opened the stream, which on a phone away from wifi is
// long enough to tap again.
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
import 'package:muse/src/ui/song_row.dart';
import 'package:muse/src/ui/swipe.dart';

import 'fake_audio.dart';

Track song(int id, {String source = 'youtube'}) => Track.fromJson({
      'id': id,
      'title': 'Song $id',
      'artists': ['Someone'],
      'state': 'ready',
      'stream_url': '/tracks/$id/stream',
      'source': source,
    });

const nothing = (trackId: null, itemId: null, playing: false, buffering: false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const session = MethodChannel('com.ryanheise.audio_session');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(session, (call) async => null);

  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    JustAudioPlatform.instance = FakeJustAudio();
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
    app.player = PlayerService(app.api);
  });

  Future<void> show(WidgetTester tester, List<Widget> rows) async {
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(home: Scaffold(body: Column(children: rows))),
    ));
    await tester.pump();
  }

  /// Past the cross-fade a mark leaves by, and the frame after it in which the
  /// switcher lets go of it. Not pumpAndSettle: the bars never settle while playing.
  Future<void> gone(WidgetTester tester) async {
    await tester.pump(); // the frame the cross-fade starts on
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(); // the frame the switcher lets go on
  }

  Finder inRow(int id, Finder what) => find.descendant(
      of: find.ancestor(of: find.text('Song $id'), matching: find.byType(SongRow)),
      matching: what);

  testWidgets('the song playing is lit in any list, not only the queue',
      (tester) async {
    app.player!.playingNow.value =
        (trackId: 2, itemId: null, playing: true, buffering: false);
    await show(tester, [
      SongRow(track: song(1), onTap: () {}),
      SongRow(track: song(2), onTap: () {}),
    ]);
    await tester.pump(const Duration(milliseconds: 400));

    expect(inRow(2, find.byType(PlayingBars)), findsOneWidget,
        reason: 'the sound is drawn on the record playing');
    expect(inRow(1, find.byType(PlayingBars)), findsNothing);

    // And it follows the player: the next song lights, the last goes out.
    app.player!.playingNow.value =
        (trackId: 1, itemId: null, playing: true, buffering: false);
    await gone(tester);
    expect(inRow(1, find.byType(PlayingBars)), findsOneWidget);
    expect(inRow(2, find.byType(PlayingBars)), findsNothing);
  });

  testWidgets('a tap is answered at once, and the answer goes when the player catches up',
      (tester) async {
    await show(tester, [SongRow(track: song(1), onTap: () {})]);
    expect(inRow(1, find.byType(CircularProgressIndicator)), findsNothing);

    await tester.tap(find.text('Song 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(inRow(1, find.byType(CircularProgressIndicator)), findsOneWidget,
        reason: 'the row says the tap was taken before anything has played');

    app.player!.playingNow.value =
        (trackId: 1, itemId: null, playing: true, buffering: false);
    await gone(tester);
    expect(inRow(1, find.byType(CircularProgressIndicator)), findsNothing);
    expect(inRow(1, find.byType(PlayingBars)), findsOneWidget);
  });

  testWidgets('a row whose tap does not play the song does not say it is starting',
      (tester) async {
    await show(tester, [SongRow(track: song(1), plays: false, onTap: () {})]);
    await tester.tap(find.text('Song 1'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(inRow(1, find.byType(CircularProgressIndicator)), findsNothing);
  });

  testWidgets('a tap nobody answers stops claiming to be starting', (tester) async {
    await show(tester, [SongRow(track: song(1), onTap: () {})]);
    await tester.tap(find.text('Song 1'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(inRow(1, find.byType(CircularProgressIndicator)), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
    await gone(tester);
    expect(inRow(1, find.byType(CircularProgressIndicator)), findsNothing,
        reason: 'a spinner that never stops is a lie');
  });

  testWidgets('where a song came from is said in letters, and not for YouTube',
      (tester) async {
    await show(tester, [
      SongRow(track: song(1), onTap: () {}),
      SongRow(track: song(2, source: 'bandcamp'), onTap: () {}),
      SongRow(track: song(3, source: 'soundcloud'), onTap: () {}),
    ]);
    expect(inRow(1, find.byType(SourceTag)), findsNothing,
        reason: 'nearly everything is; a tag on every row is a tag on none');
    expect(find.text('BC'), findsOneWidget);
    expect(find.text('SC'), findsOneWidget);
  });

  testWidgets('the back of a pushed row names what letting go will do once caught',
      (tester) async {
    Future<void> at(double progress) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 56,
            child: SwipeBack(
                icon: Icons.playlist_play, label: 'Play next', progress: progress),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    double wordShown() =>
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

    await at(0.2);
    expect(wordShown(), 0, reason: 'not far enough to mean it yet');
    await at(0.6);
    expect(wordShown(), 1);
    expect(find.text('PLAY NEXT'), findsOneWidget);
  });

  testWidgets('the back of a queue row hears the drag through the Pushable',
      (tester) async {
    late void Function(double) report;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 300,
          height: 56,
          child: Pushable(
            child: const Text('row'),
            builder: (context, row, r) {
              report = r;
              return Stack(children: [
                const Positioned.fill(
                    child: SwipeBack(
                        away: true, icon: Icons.delete_outline, label: 'Remove')),
                row,
              ]);
            },
          ),
        ),
      ),
    ));
    expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 0);
    report(0.7);
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 1,
        reason: 'the Dismissible reports to the Pushable, and the back is inside it');
  });
}
