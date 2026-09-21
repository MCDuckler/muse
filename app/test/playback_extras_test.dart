// The player's extras sheet: how it sounds, how songs join, the sleep timer.
//
// The equalizer's curves are a tap away here, without leaving the player; "one song into
// the next" is a switch; and none of it breaks on a small phone with the type turned up.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/equalizer.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/now_playing.dart';

class Told extends EqEngine {
  final said = <({bool enabled, List<double> gains})>[];
  @override
  bool get available => true;
  @override
  List<EqBand> get bands => [for (final hz in eqFrequencies) EqBand(hz)];
  @override
  Future<void> prepare() async {}
  @override
  Future<void> apply(
      {required bool enabled, required List<double> gains, required double preamp}) async {
    said.add((enabled: enabled, gains: gains));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late Told engine;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    engine = Told();
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
    app.equalizer.engine = engine;
  });

  Future<void> open(WidgetTester tester,
      {Size size = const Size(420, 900), double text = 1}) async {
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
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(text)),
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                  onPressed: () => showPlaybackExtras(context), child: const Text('open')),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a curve is a tap away, and so is switching it off', (tester) async {
    await open(tester);
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(ChoiceChip, 'Off'), findsOneWidget);

    // The row scrolls sideways; the test font is wide, so bring the chip into view.
    final chip = find.widgetWithText(ChoiceChip, 'Loudness');
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(app.equalizer.enabled, isTrue);
    expect(app.equalizer.current?.name, 'Loudness');
    expect(engine.said.last.gains.first, 6);
    expect(find.text('Loudness'), findsNWidgets(2), reason: 'the chip, and the line above');

    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Off'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, 'Off'));
    await tester.pumpAndSettle();
    expect(engine.said.last.enabled, isFalse);
  });

  testWidgets('one song into the next is a switch, remembered', (tester) async {
    await open(tester);
    expect(app.seamless, isTrue);
    await tester.tap(find.text('One song into the next'));
    await tester.pumpAndSettle();
    expect(app.seamless, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('muse.seamless'), isFalse);
  });

  testWidgets('a device with no equalizer offers no curves', (tester) async {
    app.equalizer.engine = NoEqEngine();
    await open(tester);
    expect(find.widgetWithText(ChoiceChip, 'Flat'), findsNothing);
    expect(find.widgetWithText(ChoiceChip, 'Off'), findsNothing);
    expect(find.text('Equalizer'), findsOneWidget, reason: 'the way to the page that says why');
  });

  for (final scale in [1.6, 2.0]) {
    testWidgets('it holds on a small phone at ${scale}x text', (tester) async {
      await open(tester, size: const Size(320, 900), text: scale);
      expect(tester.takeException(), isNull);
    });
  }
}
