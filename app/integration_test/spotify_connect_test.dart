// Does "Connect Spotify" actually open Spotify?
//
// It used to look like it did: the button fetched the sign-in address and *then* asked
// the browser for a tab. A browser only opens one while it can still see the tap that
// asked, so by then it was blocked — silently, because window.open cannot report it —
// and all that happened was a snackbar saying to finish signing in.
//
// So this asserts on the window the browser was asked for, and on the fact that it was
// asked during the tap rather than after an await.
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:muse/main.dart' as app;

@JS('eval')
external JSAny? _eval(String script);

void _watchWindowOpen() {
  _eval(r"""
    window.__opened = [];
    var real = window.open;
    window.open = function(url) {
      window.__opened.push(String(url));
      return null;            // what a popup blocker returns; the app must survive it
    };
  """);
}

String _opened() =>
    (_eval('(window.__opened || []).join(" ~ ")') as JSString?)?.toDart ?? '';

const user = String.fromEnvironment('MUSE_USER', defaultValue: 'chris');
const pass = String.fromEnvironment('MUSE_PASS');

Future<void> settle(WidgetTester tester, {int seconds = 3}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    tester.takeException();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Connect Spotify opens Spotify', (tester) async {
    _watchWindowOpen();
    app.main();
    await settle(tester, seconds: 4);

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2), reason: 'login screen should be up');
    await tester.enterText(fields.at(0), user);
    await tester.enterText(fields.at(1), pass);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await settle(tester, seconds: 8);

    // Settings, Connected services, then the Spotify row. It used to sit at the
    // bottom of the Library tab as well; it lives with the other services now.
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester, seconds: 3);
    final services = find.widgetWithText(ListTile, 'Connected services');
    await tester.scrollUntilVisible(services, 160,
        scrollable: find.byType(Scrollable).last);
    await settle(tester);
    await tester.tap(services);
    await settle(tester, seconds: 3);
    final row = find.widgetWithText(ListTile, 'Spotify');
    await tester.scrollUntilVisible(row, 160,
        scrollable: find.byType(Scrollable).last);
    await settle(tester);
    await tester.tap(row);
    await settle(tester, seconds: 5);

    final connect = find.widgetWithText(FilledButton, 'Connect Spotify');
    expect(connect, findsOneWidget,
        reason: 'this account must not be connected for the test to mean anything');

    // The screen has had time to fetch an address; the tap must spend no time at all.
    expect(_opened(), isEmpty, reason: 'nothing should have opened before the tap');
    await tester.tap(connect);
    // No settle first: this is the whole point. A browser gives the app one moment
    // after a tap to open a window, and the address has to already be in hand.
    await tester.pump();

    expect(_opened(), contains('accounts.spotify.com'),
        reason: 'the tap itself must ask for the Spotify tab. opened=${_opened()}');
    expect(_opened(), contains('redirect_uri'),
        reason: 'and it must be the full authorize URL. opened=${_opened()}');

    // A blocked popup (window.open returning null) must not break the screen.
    await settle(tester, seconds: 3);
    expect(tester.takeException(), isNull);
  });
}
