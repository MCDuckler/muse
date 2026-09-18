// The player screen on a desk.
//
// It was a phone screen stretched: one tall column, so a record blown up to nine
// hundred pixels tall pushed its own title off the bottom of the window. On a desk the
// record and what is said about it stand side by side.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/now_playing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    app = AppState()..api = ApiClient(baseUrl: 'http://example.invalid');
  });

  Future<void> show(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: const MaterialApp(home: NowPlayingScreen()),
    ));
    await tester.pump();
  }

  testWidgets('it builds at both widths with nothing playing', (tester) async {
    // No player at all is the state a fresh install is in, and the screen is
    // reachable from the bar before anything has been pressed.
    for (final size in [const Size(420, 900), const Size(1440, 900)]) {
      await show(tester, size);
      expect(tester.takeException(), isNull, reason: 'at ${size.width} wide');
    }
    // The screen schedules a look at the background service; let it run out.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  });
}
