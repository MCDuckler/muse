// The equalizer: a curve somebody drew, and whatever this device can do about it.
//
// The curve is the truth and an engine samples it, so a preset is the same preset on a
// phone with five bands as in a browser with ten. It turns itself down by as much as it
// turns anything up; the two amp knobs are a way of moving the faders rather than a
// second setting; all of it is remembered; and the page works it.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/eq_engines.dart';
import 'package:muse/src/state/equalizer.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/equalizer_page.dart';

import 'fake_audio.dart';

/// An engine that writes down what it was told.
class Told extends EqEngine {
  Told([List<double>? hz]) : _hz = hz ?? eqFrequencies;
  final List<double> _hz;
  final said = <({bool enabled, List<double> gains, double preamp})>[];

  @override
  bool get available => true;
  @override
  List<EqBand> get bands => [for (final hz in _hz) EqBand(hz)];
  @override
  Future<void> prepare() async {}
  @override
  Future<void> apply(
      {required bool enabled, required List<double> gains, required double preamp}) async {
    said.add((enabled: enabled, gains: gains, preamp: preamp));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the curve is read off between the ten, as the ear hears the distance', () {
    final g = eqPresets.firstWhere((p) => p.name == 'Bass lift').gains;
    expect(eqCurveAt(g, 62.5), 6);
    expect(eqCurveAt(g, 20), 7, reason: 'level beyond either end');
    // Halfway between 62.5 and 125 *by ear* is 88 Hz, not 94.
    expect(eqCurveAt(g, 88.39), closeTo(5, 0.01));
  });

  test('a phone with five bands of its own is given the curve at those five', () async {
    final engine = Told(const [60, 230, 910, 3600, 14000]);
    final eq = Equalizer(engine);
    await eq.use(eqPresets.firstWhere((p) => p.name == 'Loudness'));
    final told = engine.said.last;
    expect(told.enabled, isTrue, reason: 'choosing a curve is asking to hear it');
    expect(told.gains.length, 5);
    expect(told.gains.first, closeTo(5.06, 0.1), reason: 'just under the 62 Hz point');
    expect(told.gains[2], closeTo(0, 0.2));
    expect(told.gains.last, greaterThan(3));
  });

  test('it turns itself down by as much as it turns anything up', () async {
    final engine = Told();
    final eq = Equalizer(engine);
    await eq.use(eqPresets.firstWhere((p) => p.name == 'Bass lift'));   // +7 at the bottom
    expect(eq.headroom, -7);
    expect(engine.said.last.preamp, -7);

    await eq.setPreamp(2);
    expect(engine.said.last.preamp, -5, reason: 'what was asked for, less the headroom');

    // A curve that only cuts needs no room made for it.
    await eq.use(eqPresets.firstWhere((p) => p.name == 'Late night'));
    await eq.setPreamp(0);
    expect(eq.headroom, -2, reason: 'its highest point is +2');

    await eq.setProtect(false);
    expect(engine.said.last.preamp, 0);
  });

  test('the knobs move the faders, and read back from them', () async {
    final eq = Equalizer(Told());
    await eq.setBass(6);
    expect(eq.gains.first, 6);
    expect(eq.gains[3], closeTo(2.1, 0.01), reason: 'a shelf: tapering off by 250 Hz');
    expect(eq.gains[5], 0, reason: 'and nothing in the middle');
    expect(eq.bass, closeTo(6, 0.01));
    expect(eq.treble, closeTo(0, 0.01));

    await eq.setTreble(-4);
    expect(eq.gains.last, -4);
    expect(eq.bass, closeTo(6, 0.01), reason: 'one knob does not turn the other');
    expect(eq.current, isNull, reason: 'a curve of your own');
  });

  test('held flat is heard flat, and let go is the curve again', () async {
    final engine = Told();
    final eq = Equalizer(engine);
    await eq.use(eqPresets[1]);
    await eq.listenFlat(true);
    expect(engine.said.last.enabled, isFalse);
    expect(eq.enabled, isTrue, reason: 'not switched off: held');
    await eq.listenFlat(false);
    expect(engine.said.last.enabled, isTrue);
  });

  test('a curve kept under a name is there next time, and so is everything else', () async {
    final eq = Equalizer(Told());
    await eq.setBand(4, 3.5);
    await eq.saveAs('  Kitchen speaker ');
    await eq.setPreamp(-2);
    await eq.setEnabled(true);

    final engine = Told();
    final again = Equalizer(engine);
    await again.start();
    expect(again.enabled, isTrue);
    expect(again.gains[4], 3.5);
    expect(again.preamp, -2);
    expect(again.custom.single.name, 'Kitchen speaker');
    expect(again.current?.name, 'Kitchen speaker');
    expect(engine.said.last.gains[4], 3.5, reason: 'and the sound is made to match');

    // The same name again replaces it rather than making a second.
    await again.setBand(4, 1);
    await again.saveAs('kitchen speaker');
    expect(again.custom.length, 1);
    await again.forget(again.custom.single);
    expect(again.custom, isEmpty);
  });

  test("Android's own equalizer: cuts go to the bands, a boost to the loudness stage",
      () async {
    const session = MethodChannel('com.ryanheise.audio_session');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(session, (call) async => null);
    final phone = FakeJustAudio();
    JustAudioPlatform.instance = phone;
    final equalizer = AndroidEqualizer(), loudness = AndroidLoudnessEnhancer();
    final player = AudioPlayer(
        audioPipeline: AudioPipeline(androidAudioEffects: [loudness, equalizer]));
    addTearDown(player.dispose);
    // The system's equalizer only exists once the player has something to play.
    await player.setAudioSource(AudioSource.uri(Uri.parse('http://example.invalid/a.m4a')));

    final engine = AndroidEqEngine(equalizer, loudness);
    final eq = Equalizer(engine);
    await eq.start();
    expect(engine.available, isTrue);
    expect([for (final b in engine.bands) b.hz], FakeAudioPlayer.bandHz);

    await eq.use(eqPresets.firstWhere((p) => p.name == 'Bass lift'));
    final heard = phone.only;
    // +7 at the bottom with 7 dB of headroom: the bottom band at about zero, the rest
    // seven down — the same shape, with nothing above what the record can hold.
    expect(heard.bandGains.first, closeTo(-0.9, 0.3));
    expect(heard.bandGains.last, closeTo(-7, 0.01));
    expect(heard.effectsOn['AndroidEqualizer'], isTrue);
    expect(heard.effectsOn['AndroidLoudnessEnhancer'] ?? false, isFalse);

    await eq.setProtect(false);
    await eq.setPreamp(4);
    expect(heard.bandGains.first, closeTo(6.1, 0.3));
    expect(heard.loudnessGain, 4);
    expect(heard.effectsOn['AndroidLoudnessEnhancer'], isTrue);
  });

  group('the page', () {
    late AppState app;
    late Told engine;

    setUp(() {
      engine = Told();
      app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
      app.equalizer.engine = engine;
    });

    Future<void> show(WidgetTester tester,
        {Size size = const Size(420, 1500), double text = 1}) async {
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
            child: const EqualizerPage(),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('a sticker is a curve, and choosing one switches it on', (tester) async {
      await show(tester);
      expect(tester.takeException(), isNull);
      expect(app.equalizer.enabled, isFalse);

      await tester.tap(find.text('SMALL SPEAKERS'));
      await tester.pump();
      expect(app.equalizer.enabled, isTrue);
      expect(engine.said.last.gains.first, -6);
      expect(find.text('“Small speakers”'), findsOneWidget);

      // Off again at the switch, and the engine is told.
      await tester.tap(find.text('OFF'));
      await tester.pump();
      expect(engine.said.last.enabled, isFalse);
    });

    testWidgets('a fader dragged is a band set, and a curve of your own can be kept',
        (tester) async {
      await show(tester);
      await tester.tap(find.text('ON'));
      await tester.pump();

      final fader = find.bySemanticsLabel('1k hertz');
      await tester.drag(fader, const Offset(0, -60));
      await tester.pump();
      expect(app.equalizer.gains[5], greaterThan(3));
      expect(find.text('A curve of your own.'), findsOneWidget);

      await tester.tap(find.text('+ KEEP THIS ONE'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'The car');
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(find.text('THE CAR'), findsOneWidget);
      expect(find.text('+ KEEP THIS ONE'), findsNothing, reason: 'it is one of them now');

      // Twice on a fader puts it back to centre.
      await tester.tap(fader);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(fader);
      await tester.pumpAndSettle();
      expect(app.equalizer.gains[5].abs(), lessThan(3.5));
    });

    testWidgets('a finger drawn across the graph is the curve', (tester) async {
      await show(tester);
      final graph = tester.getRect(find.bySemanticsLabel(RegExp('Response curve')));
      // Low on the left, high on the right: less bass and more top, in one stroke.
      final finger = await tester.startGesture(graph.bottomLeft + const Offset(36, -30));
      await tester.pump();
      expect(app.equalizer.enabled, isTrue, reason: 'drawing a curve is asking to hear it');
      for (var i = 1; i <= 12; i++) {
        await finger.moveTo(Offset.lerp(graph.bottomLeft + const Offset(36, -30),
            graph.topRight + const Offset(-14, 16), i / 12)!);
        await tester.pump();
      }
      await finger.up();
      await tester.pump();

      final g = app.equalizer.gains;
      expect(g.first, lessThan(-4));
      expect(g.last, greaterThan(4));
      for (var i = 1; i < g.length; i++) {
        expect(g[i], greaterThanOrEqualTo(g[i - 1]), reason: 'every band it passed, in order');
      }
      expect(engine.said.last.gains.last, g.last, reason: 'and the sound followed');
      expect(tester.takeException(), isNull);
      // What it came to rest at is written down a moment later, not on every move.
      await tester.pump(const Duration(milliseconds: 500));
    });

    testWidgets('a device with no equalizer says so, and nothing can be pushed',
        (tester) async {
      app.equalizer.engine = NoEqEngine('Not on this one.');
      await show(tester);
      expect(find.text('Not on this one.'), findsOneWidget);
      await tester.tap(find.text('ON'), warnIfMissed: false);
      await tester.pump();
      expect(app.equalizer.enabled, isFalse);
    });

    testWidgets('a phone with five bands says the curve is fitted to them', (tester) async {
      app.equalizer.engine = Told(const [60, 230, 910, 3600, 14000]);
      await show(tester);
      expect(find.textContaining('5 bands of its own'), findsOneWidget);
    });

    for (final scale in [1.6, 2.0]) {
      testWidgets('it holds on a small phone at ${scale}x text', (tester) async {
        await app.equalizer.use(eqPresets[2]);
        await show(tester, size: const Size(320, 2400), text: scale);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('KNOBS'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('BASS'), findsOneWidget);
      });
    }
  });
}
