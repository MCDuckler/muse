// Whose the native stage is: the booth's small picture yields to the stage over the
// window and takes it back; and the debug words over a Flutter-drawn surface say why.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_demo.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/ui/show/native_stage.dart';
import 'package:muse/src/ui/show/scene.dart';
import 'package:muse/src/ui/show/show_debug.dart';
import 'package:muse/src/ui/show/stage_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final tile = Object(), page = Object(), other = Object();

  tearDown(() {
    NativeStage.release(tile);
    NativeStage.release(page);
    NativeStage.release(other);
  });

  test('the stage page takes the stage from the booth\'s picture, which takes it back', () {
    expect(NativeStage.claim(tile), isTrue);
    expect(NativeStage.claim(tile), isTrue);
    expect(NativeStage.ownerWord, contains('small picture'));
    expect(NativeStage.claim(page, rank: 2), isTrue);
    expect(NativeStage.owns(page), isTrue);
    expect(NativeStage.claim(tile), isFalse);
    expect(NativeStage.ownerWord, contains('stage over the window'));
    // Another show (a second page) does not take it from the first.
    expect(NativeStage.claim(other, rank: 2), isFalse);
    NativeStage.release(page);
    expect(NativeStage.claim(tile), isTrue);
  });

  test('given up is for a while, not for good', () {
    NativeStage.brokenUntil = DateTime.now().add(const Duration(seconds: 5));
    NativeStage.brokenWhy = 'no frame';
    // Under a test the native stage is never wanted; the reason says so first.
    expect(NativeStage.whyNot(), 'a test');
    NativeStage.brokenUntil = DateTime.now().subtract(const Duration(seconds: 1));
    expect(NativeStage.whyNot(), 'a test');
    NativeStage.brokenUntil = null;
  });

  test("a scene through a treatment is the Flutter stage's; the dancers' own rendering of one is not", () {
    const kinetic = RigFigure(kind: Figure.kinetic);
    expect(NativeStage.whyNotRig(const ShowRig(figure: kinetic)), isNull);
    expect(NativeStage.whyNotRig(ShowRig(figure: kinetic.copyWith(treatment: Treatment.ascii))), contains('ascii'));
    const dancers = RigFigure(kind: Figure.dancers, treatment: Treatment.lines, style: 'lines');
    expect(NativeStage.whyNotRig(const ShowRig(figure: dancers)), isNull, reason: 'they draw it themselves');
    expect(NativeStage.whyNotRig(ShowRig(figure: dancers.copyWith(style: 'chrono'))), isNotNull, reason: 'chrono through lines is the pass');
    expect(NativeStage.whyNotRig(ShowRig(figure: kinetic.copyWith(treatment: Treatment.raw))), isNull);
  });

  testWidgets('the debug words say which stage draws, and why', (tester) async {
    SharedPreferences.setMockInitialValues({'muse.show.debug': true});
    final kit = await StageKit.load();
    final feed = DemoShowFeed(scenes: kit.book.metas, looks: kit.book.looks);
    final info = ValueNotifier(StageInfo.none);
    await tester.pumpWidget(MaterialApp(
      home: SizedBox(width: 320, height: 180, child: StageSurface(feed: feed, book: kit.book, programs: kit.programs, info: info)),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    expect(ShowDebug.on.value, isTrue);
    expect(find.textContaining('FLUTTER'), findsOneWidget);
    expect(find.textContaining('why not native: a test'), findsOneWidget);
    expect(info.value.native, isFalse);
    expect(info.value.why, 'a test');
    // Switched off, the words go.
    ShowDebug.on.value = false;
    await tester.pump();
    expect(find.textContaining('FLUTTER'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    feed.dispose();
  });

  // (Through the kit, which keeps its value: a future Flutter's asset bundle cached in
  // an earlier test's zone never delivers to this one.)
  testWidgets('every scene file reads as a look with the right layers', (tester) async {
    final book = (await StageKit.load()).book;
    final looks = book.looks;
    expect(looks['milk']!.rig.ground.kind, equals(Ground.milk));
    expect(looks['milk']!.rig.figure.kind, Figure.none);
    expect(looks['kinetic']!.rig.figure.kind, Figure.kinetic);
    expect(looks['drift']!.rig.ground.kind, Ground.field);
    expect(looks['drift']!.rig.ground.field, 'drift');
    expect(looks['echo']!.rig.ground.kind, Ground.camera);
    expect(looks['echo']!.rig.ground.treatment, 'echo');
    expect(looks['dance-art']!.rig.figure.kind, Figure.dancers);
    expect(looks['dance-art']!.rig.figure.dressing, Dressing.none);
    expect(looks['dance-disco']!.rig.figure.dressing, Dressing.disco);
    expect(looks['flock']!.rig.figure.kind, Figure.birds);
    expect(looks['veins']!.rig.figure.kind, Figure.veins);
    expect(looks['siebenschlaefer']!.rig.figure.kind, Figure.meme);
    expect(looks['kinetic']!.rig.finish.trails, 0.35);
    expect(looks['kinetic']!.rig.finish.particles, ['sparks']);
    expect(looks['drift']!.rig.finish.title, isTrue);
    expect(looks['drift']!.meta.sections, contains('breakdown'));
    for (final l in looks.values) {
      expect(l.shipped, isTrue, reason: l.id);
    }
  });
}
