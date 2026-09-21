// Choosing how many covers go across the album list, on the page itself: the menu is
// there, picking a number changes the wall, the choice is kept, and a wall of covers too
// small to write under still says what each one is.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    useThisClientInstead(MockClient((request) async {
      final body = request.url.path.endsWith('/index')
          ? {'letters': []}
          : {
              'total': 12,
              'items': [
                for (var i = 0; i < 12; i++)
                  {'name': 'Record $i', 'artist': 'Somebody', 'tracks': 9}
              ],
            };
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() => useThisClientInstead(http.Client()));

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: const MaterialApp(home: AlbumsPage()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  double leftOf(WidgetTester tester, String name) => tester.getTopLeft(find.text(name)).dx;

  testWidgets('two across until asked, then as many as asked for', (tester) async {
    await show(tester);
    expect(tester.takeException(), isNull);
    // Two across: the third record is back under the first.
    expect(leftOf(tester, 'Record 2'), leftOf(tester, 'Record 0'));

    await tester.tap(find.byTooltip('Covers across'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3 across'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(app.albumsAcross, 3);
    expect(leftOf(tester, 'Record 3'), leftOf(tester, 'Record 0'));
    expect(leftOf(tester, 'Record 2'), greaterThan(leftOf(tester, 'Record 1')));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('muse.albumsAcross'), 3, reason: 'kept for next time');
  });

  testWidgets('covers too small to write under still say what they are', (tester) async {
    await app.setAlbumsAcross(5);
    await show(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Record 0'), findsNothing);
    expect(find.byTooltip('Record 0 · Somebody · 9 tracks'), findsOneWidget);
  });

  testWidgets('and it can be handed back', (tester) async {
    await app.setAlbumsAcross(4);
    await show(tester);
    await tester.tap(find.byTooltip('Covers across'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('As many as fit well'));
    await tester.pumpAndSettle();
    expect(app.albumsAcross, isNull);
    expect(leftOf(tester, 'Record 2'), leftOf(tester, 'Record 0'));
  });
}
