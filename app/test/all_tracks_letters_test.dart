// The songs list, with the alphabet down its side.
//
// Newest-first is not an alphabet and has no rail. By title it has one, asked for in
// that order; and a letter a long way down fetches that far and puts the list there.
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
import 'package:muse/src/ui/browse_page.dart';
import 'package:muse/src/ui/letter_rail.dart';

const total = 900;

String titleAt(int i) =>
    '${String.fromCharCode(65 + (i * 26) ~/ total)} song ${i.toString().padLeft(4, '0')}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late List<Uri> asked;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    asked = [];
    useThisClientInstead(MockClient((request) async {
      asked.add(request.url);
      final q = request.url.queryParameters;
      Object body = <String, dynamic>{};
      if (request.url.path == '/library/tracks') {
        final from = int.parse(q['offset'] ?? '0'), n = int.parse(q['limit'] ?? '200');
        body = {
          'total': total,
          'items': [
            for (var i = from; i < from + n && i < total; i++)
              {'id': i + 1, 'title': titleAt(i), 'artists': ['Someone'], 'state': 'ready'},
          ],
        };
      } else if (request.url.path == '/library/tracks/index') {
        body = {
          'letters': [
            for (var l = 0; l < 26; l++)
              {'letter': String.fromCharCode(65 + l), 'offset': (l * total / 26).ceil()},
          ],
        };
      }
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() => useThisClientInstead(http.Client()));

  testWidgets('by title there is a rail, and a letter goes to where it starts',
      (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: const MaterialApp(home: AllTracksPage()),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.byType(LetterRail), findsNothing, reason: 'newest first has no letters');

    await tester.tap(find.byTooltip('Sort'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Title').last);
    await tester.pumpAndSettle();
    expect(asked.any((u) =>
        u.path == '/library/tracks/index' && u.queryParameters['sort'] == 'title'), isTrue);
    expect(find.byType(LetterRail), findsOneWidget);

    // Near the bottom of the rail: a letter far beyond the first page.
    // The strip of letters itself: it is centred in the room the rail is given.
    final rail = tester.getRect(find
        .descendant(of: find.byType(LetterRail), matching: find.byType(GestureDetector))
        .first);
    final finger = await tester.startGesture(Offset(rail.right - 8, rail.bottom - 6));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await finger.up();
    await tester.pump();

    expect(asked.where((u) => u.path == '/library/tracks').length, greaterThan(2),
        reason: 'fetched that far, a page at a time');
    expect(find.textContaining(RegExp(r'^Z song')), findsWidgets,
        reason: 'and the list is at the Zs');
    expect(tester.takeException(), isNull);
  });
}
