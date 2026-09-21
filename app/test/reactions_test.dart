// A nod at what somebody has on.
//
// One arriving comes up the screen with who it was from and is gone again by itself;
// sending one asks the server for exactly that, and goes up your own screen too, so the
// button visibly did something.
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
import 'package:muse/src/ui/reactions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late List<http.Request> sent;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    sent = [];
    useThisClientInstead(MockClient((request) async {
      sent.add(request);
      return http.Response('{"sent": "x"}', 200,
          headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() => useThisClientInstead(http.Client()));

  Future<void> show(WidgetTester tester) => tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: const MaterialApp(
            home: ReactionLayer(
              child: Scaffold(
                body: Center(
                    child: ReactionRow(personId: 2, name: 'Joe', trackId: 40)),
              ),
            ),
          ),
        ),
      );

  testWidgets('sending one asks for it, and shows that it went', (tester) async {
    await show(tester);
    await tester.tap(find.text('🔥'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(sent.single.url.path, '/social/people/2/react');
    expect(jsonDecode(sent.single.body), {'emoji': '🔥', 'track_id': 40});
    expect(find.text('TO JOE'), findsOneWidget);

    // Gone by itself, and nothing left behind on the screen.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('TO JOE'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one arriving says who it was from', (tester) async {
    await show(tester);
    // As the event stream would: see AppState._listenForEvents.
    app.heardAReaction({'from': 'Sam', 'emoji': '🕺'});
    app.heardAReaction({'from': 'Sam', 'emoji': '<b>not one of them</b>'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('SAM'), findsOneWidget, reason: 'the one that is a reaction');
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('SAM'), findsNothing);
  });
}
