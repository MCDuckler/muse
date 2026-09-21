// Jump to anything.
//
// The palette matches what is already in the app's hands as you type — commands,
// playlists, queues — asks the library a moment after you stop, and does the thing on
// return. These hold it to that, and to the matching rules that decide what comes first.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/ui/command_palette.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('what matches, and how well', () {
    test('the start beats a word, a word beats the middle, the middle beats letters', () {
      expect(matchScore('sun', 'Sunday Driving'), 4);
      expect(matchScore('dri', 'Sunday Driving'), 3);
      expect(matchScore('nday', 'Sunday Driving'), 2);
      expect(matchScore('sdv', 'Sunday Driving'), 1);
      expect(matchScore('xyz', 'Sunday Driving'), 0);
    });

    test('an empty question matches everything', () {
      expect(matchScore('', 'Anything'), greaterThan(0));
    });
  });

  group('the palette', () {
    late AppState app;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      useThisClientInstead(MockClient((request) async => http.Response(
          jsonEncode(request.url.path == '/search/everything'
              ? {
                  'items': [
                    {
                      'kind': 'song',
                      'place': 'library',
                      'id': '9',
                      'title': 'Harbour Lights',
                      'subtitle': 'Low Tide Radio',
                    },
                  ],
                }
              : <String, dynamic>{}),
          200,
          headers: {'content-type': 'application/json'})));
      app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
      app.playlists = [
        Playlist.fromJson({'id': 5, 'name': 'Sunday Driving', 'items': 12}),
        Playlist.fromJson({'id': 6, 'name': 'Gym', 'items': 40}),
      ];
    });

    tearDown(() => useThisClientInstead(http.Client()));

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showCommandPalette(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('a command, typed and run with return', (tester) async {
      await open(tester);
      expect(find.text('JUMP TO'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'newsprint');
      await tester.pump();
      expect(find.text('Print the Newsprint edition'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(app.palette.id, 'newsprint');
      expect(find.text('JUMP TO'), findsNothing, reason: 'and it gets out of the way');
    });

    testWidgets('a playlist, by the start of its name', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), 'sun');
      await tester.pump();
      expect(find.text('Sunday Driving'), findsOneWidget);
      expect(find.text('Gym'), findsNothing);
      expect(find.text('PLAYLISTS'), findsOneWidget);
    });

    testWidgets('the library is asked once the typing stops', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), 'harbour');
      await tester.pump(const Duration(milliseconds: 300));   // past the pause
      await tester.pump();
      await tester.pump();
      expect(find.text('Harbour Lights'), findsOneWidget);
      expect(find.text('SONGS'), findsOneWidget);
    });

    testWidgets('down and up move through what it found', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), 'sleep');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
