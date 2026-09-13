// The people tab.
//
// The catalog has always been shared and there was no way to see that. What this
// checks is the part that has to be visible without being gone looking for: who is
// here, and that one of them has a jam going right now.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/social_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late List<Uri> asked;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    asked = [];
    useThisClientInstead(MockClient((request) async {
      asked.add(request.url);
      final path = request.url.path;
      if (path == '/social/people') {
        return http.Response(
          jsonEncode({
            'you': 1,
            'people': [
              {'id': 1, 'name': 'chris', 'songs': 12, 'playlists': 2},
              {
                'id': 2,
                'name': 'joe',
                'songs': 3,
                'playlists': 1,
                'jam': {'code': 'ABCD', 'people': 2},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json'});
    }));

    final api = ApiClient(baseUrl: 'http://example.invalid');
    api.token = 'test-token';
    app = AppState()..api = api;
  });

  tearDown(() => useThisClientInstead(http.Client()));

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: const MaterialApp(home: Scaffold(body: SocialPage())),
    ));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('everybody here is listed, with what they have', (tester) async {
    await show(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('chris'), findsOneWidget);
    expect(find.text('joe'), findsOneWidget);
    expect(find.text('you'), findsOneWidget, reason: 'which one of them is you');
    expect(find.text('12 songs · 2 playlists'), findsOneWidget);
  });

  testWidgets('a jam is visible without being looked for, and joinable from the row',
      (tester) async {
    await show(tester);
    expect(find.text('In a jam · 2 listening'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Join'), findsOneWidget,
        reason: 'and the way in is on the row, not two screens away');

    // Whoever has a jam going comes first, whatever their name: a list sorted by
    // anything else buries the one thing on it that is happening now.
    final names = tester
        .widgetList<Text>(find.descendant(
            of: find.byType(ListTile), matching: find.byType(Text)))
        .map((t) => t.data)
        .toList();
    expect(names.indexOf('joe') < names.indexOf('chris'), isTrue);
  });
}
