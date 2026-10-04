// A Bandcamp label's page: its acts, its records, a follow, its own words.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/bandcamp_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppState app;
  final asked = <String>[];

  setUp(() {
    asked.clear();
    SharedPreferences.setMockInitialValues({});
    useThisClientInstead(MockClient((request) async {
      asked.add('${request.method} ${request.url.path}');
      final body = switch (request.url.path) {
        '/sources/bandcamp/band' => {
            'url': 'https://ninjatune.bandcamp.com',
            'name': 'Ninja Tune',
            'is_label': true,
            'about': 'An independent record label in London, since 1990.',
            'roster': [
              {'name': 'Bonobo', 'url': 'https://bonobomusic.bandcamp.com'},
              {'name': 'Bicep', 'url': 'https://bicep.bandcamp.com'},
            ],
            'records': [
              {'remote_id': 'https://bonobomusic.bandcamp.com/album/fragments', 'title': 'Fragments', 'artist': 'Bonobo', 'record_type': 'album'},
            ],
            'following': false,
          },
        '/follows' => {'following': true},
        '/library/artists/about' => {'name': 'Someone', 'text': 'Words from SoundCloud.', 'source': 'soundcloud'},
        _ => <String, dynamic>{},
      };
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() => useThisClientInstead(http.Client()));

  Future<void> show(WidgetTester tester, Widget body) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(home: Scaffold(body: body)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets("a label's page has its acts and its records, and can be followed", (tester) async {
    await show(tester, const BandcampBandPage(url: 'https://ninjatune.bandcamp.com', name: 'Ninja Tune'));
    expect(tester.takeException(), isNull);
    expect(find.text('NINJA TUNE'), findsOneWidget);
    expect(find.text('LABEL · BANDCAMP'), findsOneWidget);
    expect(find.text('BONOBO'), findsOneWidget, reason: 'an act on the roster');
    expect(find.text('Fragments'), findsOneWidget, reason: 'a record, with whose it is');
    expect(find.text('Bonobo · album'), findsOneWidget);
    await tester.tap(find.text('FOLLOW'));
    await tester.pump();
    expect(asked, contains('POST /follows'));
    expect(find.text('FOLLOWING'), findsOneWidget);
  });

  testWidgets('About shows the words the page carries', (tester) async {
    await show(tester, const BandcampBandPage(url: 'https://ninjatune.bandcamp.com', name: 'Ninja Tune'));
    await tester.tap(find.text('ABOUT'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('independent record label'), findsOneWidget);
    expect(asked.where((a) => a.contains('/library/artists/about')), isEmpty,
        reason: 'the page already had them; nobody else was asked');
  });

  testWidgets('About for an act with no page asks where the music came from', (tester) async {
    await show(tester, Builder(builder: (context) => TextButton(
        onPressed: () => showAbout(context, 'Someone'), child: const Text('go'))));
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Words from SoundCloud.'), findsOneWidget);
    expect(find.text('FROM SOUNDCLOUD'), findsOneWidget);
  });
}
