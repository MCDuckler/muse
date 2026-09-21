// A listening diary kept elsewhere.
//
// Not connected, the card offers to be; a token pasted in goes to the server and the
// card says whose diary is being written in; and it never prints a zero or the token.
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
import 'package:muse/src/ui/scrobbling.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late List<http.Request> sent;
  var connected = false;

  setUp(() {
    connected = false;
    sent = [];
    SharedPreferences.setMockInitialValues({});
    useThisClientInstead(MockClient((request) async {
      sent.add(request);
      if (request.method == 'PUT') connected = true;
      if (request.method == 'DELETE') connected = false;
      return http.Response(
          jsonEncode({
            'listenbrainz': connected
                ? {'connected': true, 'name': 'chris_lb', 'sent': 0, 'owed': 2,
                   'error': '503: try later'}
                : {'connected': false, 'sent': 0, 'owed': 0},
          }),
          200,
          headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() => useThisClientInstead(http.Client()));

  testWidgets('a token pasted in connects it, and the card says how it is going',
      (tester) async {
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: ScrobblingCard())),
    ));
    await tester.pump();
    expect(find.text('Connect'), findsOneWidget);

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  my-token  ');
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();

    final put = sent.firstWhere((r) => r.method == 'PUT');
    expect(put.url.path, '/scrobbling/listenbrainz');
    expect(jsonDecode(put.body), {'token': 'my-token'});

    expect(find.textContaining('Writing to chris_lb'), findsWidgets);
    expect(find.textContaining('2 waiting to go'), findsOneWidget);
    expect(find.textContaining('0 sent'), findsNothing, reason: 'never a zero');
    expect(find.textContaining('Nothing is lost'), findsOneWidget);
    expect(find.textContaining('my-token'), findsNothing);

    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle(const Duration(seconds: 6));
    expect(find.text('Connect'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
