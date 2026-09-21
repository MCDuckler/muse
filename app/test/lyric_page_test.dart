// The lyrics, as a printed lyric page.
//
// The flag and the song set big over a rule; the synced words with the line being sung
// marked in highlighter; and a tap on a line going to it.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/ui/lyrics_sheet.dart';
import 'package:muse/src/ui/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  final track = Track.fromJson({
    'id': 1,
    'title': 'Harbour Lights',
    'artists': ['Low Tide Radio'],
    'state': 'ready',
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    useThisClientInstead(MockClient((request) async => http.Response(
        jsonEncode(request.url.path == '/tracks/1/lyrics'
            ? {
                'synced': '[00:00.00]The tide comes in\n[00:04.00]and takes the words\n'
                    '[00:08.00]out past the harbour lights',
              }
            : <String, dynamic>{}),
        200,
        headers: {'content-type': 'application/json'})));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() => useThisClientInstead(http.Client()));

  testWidgets('a lyric page: the song set big, the line being sung highlighted',
      (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showLyrics(context, track),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.text('LYRICS'), findsOneWidget);
    expect(find.text('HARBOUR LIGHTS'), findsOneWidget);
    expect(find.text('LOW TIDE RADIO'), findsOneWidget);
    expect(find.text('The tide comes in'), findsOneWidget);

    // Nothing is playing, so the first line is the one being sung, and it is the one
    // with highlighter behind it.
    final highlighted = tester.widgetList<AnimatedContainer>(find.ancestor(
        of: find.text('The tide comes in'), matching: find.byType(AnimatedContainer)));
    expect(
      highlighted.any((c) => (c.decoration as BoxDecoration?)?.color == MuseTheme.highlighter),
      isTrue,
    );
  });
}
