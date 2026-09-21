// The library's contents page.
//
// Every way into the library, each with a number that is true about it — and when a
// number is not true yet, or would only be a zero, nothing rather than a zero.
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
import 'package:muse/src/ui/library_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  var unseen = 3;
  var following = 12;

  setUp(() {
    unseen = 3;
    following = 12;
    SharedPreferences.setMockInitialValues({});
    useThisClientInstead(MockClient((request) async {
      final body = switch (request.url.path) {
        '/library/tracks' => {'items': [], 'total': 22815},
        '/library/albums' => {'items': [], 'total': 1203},
        '/library/artists' => {'items': [], 'total': 4550},
        '/feed' => {'items': [], 'unseen': unseen, 'following': following},
        '/library/smart' => {
            'lists': [
              {'id': 'never', 'name': 'Never played', 'blurb': 'Not once put on', 'count': 812},
              {'id': 'once', 'name': 'Played once', 'blurb': 'Worth a second go?', 'count': 0},
            ],
          },
        '/library/smart/never' => {
            'items': [
              {'id': 3, 'title': 'Unheard Song', 'artists': ['Somebody'], 'state': 'ready'},
            ],
          },
        _ => <String, dynamic>{},
      };
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() => useThisClientInstead(http.Client()));

  Future<void> show(WidgetTester tester, {Size size = const Size(420, 1200), double text = 1}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(text)),
          child: const Scaffold(body: LibraryPage()),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('every way in, with a true number on it', (tester) async {
    await show(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('CONTENTS'), findsOneWidget);
    expect(find.text('22,815'), findsOneWidget);
    expect(find.text('1,203'), findsOneWidget);
    expect(find.text('4,550'), findsOneWidget);
    expect(find.text('3 NEW'), findsOneWidget, reason: 'news goes on a sticker');
    expect(find.text('PLAYLISTS · 0'), findsOneWidget);
  });

  testWidgets('lists that fill themselves in, and an empty one left off',
      (tester) async {
    await show(tester);
    expect(find.text('LISTS THAT FILL THEMSELVES IN'), findsOneWidget);
    expect(find.text('NEVER PLAYED'), findsOneWidget);
    expect(find.text('812'), findsOneWidget);
    expect(find.text('PLAYED ONCE'), findsNothing, reason: 'nothing in it, so not offered');

    await tester.tap(find.text('NEVER PLAYED'));
    await tester.pumpAndSettle();
    expect(find.text('Unheard Song'), findsOneWidget);
  });

  testWidgets('nothing to say is not printed as a zero', (tester) async {
    unseen = 0;
    following = 0;
    await show(tester);
    expect(find.text('0 NEW'), findsNothing);
    expect(find.text('0'), findsNothing);
    expect(find.textContaining('Follow an artist'), findsOneWidget);
  });

  for (final scale in [1.6, 2.0]) {
    testWidgets('it holds on a small phone at ${scale}x text', (tester) async {
      await show(tester, size: const Size(320, 2000), text: scale);
      expect(tester.takeException(), isNull);
    });
  }
}
