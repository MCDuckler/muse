// The combination audit's captures (tools/show-audit): the made-up record on the
// native stage, every scene's every style put on by itself (on black, as drawn) and
// every background under a plain figure, each held a few seconds and its layers
// written out a few times (NativeStage.dump) — what the audit puts together offline
// into every background, mask and blend, and scores.
//
//   wetowl --stage --demo --audit <dir>
//   wetowl --stage --demo --audit-milk <dir>      every MilkDrop preset, on its own
//
// <dir>/fig/<scene>.<style>.<n>.* and <dir>/ground/<key>.<n>.*, then <dir>/done. Each
// frame also as the stage shows it (<…>.png, StageGrabs), and <…>.meta.json says
// whether the native stage drew the scene (else the Flutter stage did, and the
// .png is the figure).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import '../../state/show/milk_feed.dart';
import '../../state/show/show_combos.dart';
import '../../state/show/show_demo.dart';
import '../../state/show/show_rig.dart';
import 'native_stage.dart';
import 'scene.dart';
import 'show_faves.dart' show StageGrabs;

/// Scenes the audit leaves out: the words want a line being sung.
const _skip = {'lyrics'};

Future<void> runStageAudit(DemoShowFeed demo, SceneBook book, String dir) async {
  final stage = NativeStage.instance;
  void say(String s) => stdout.writeln('AUDIT $s');
  if (stage == null) {
    say('no native stage');
    return;
  }
  await Directory('$dir/fig').create(recursive: true);
  await Directory('$dir/ground').create(recursive: true);
  final d = demo.director..kinds = {for (final l in book.looks.values) l.id: l.rig.figure.kind};
  await Future<void>.delayed(const Duration(seconds: 4));

  Future<bool> grab(String path, {required bool native}) async {
    final image = await StageGrabs.grab();
    if (image != null) {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (png != null) await File('$path.png').writeAsBytes(png.buffer.asUint8List());
    }
    await File('$path.meta.json').writeAsString('{"native":$native}\n');
    if (!native) return image != null;
    final out = File('$path.out');
    if (!stage.dump(path)) return false;
    for (var i = 0; i < 100 && !out.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return out.existsSync();
  }

  // Every scene's every style, by itself.
  for (final sc in d.scenes) {
    if (_skip.contains(sc.id)) continue;
    final kind = d.kinds[sc.id] ?? Figure.none;
    for (final style in stylesOfFigure(kind)) {
      final world = isWorld(sc.id, kind, style);
      final name = '$dir/fig/${sc.id}.$style';
      if (File('$name.2.meta.json').existsSync()) continue;
      d.play(Combo(ground: world ? ownGround : 'black', scene: sc.id, style: style));
      // A simulation fills over seconds; a picture is there at once.
      await Future<void>.delayed(Duration(milliseconds: sc.instant ? 2500 : 6000));
      final native = NativeStage.canDraw(book[sc.id]);
      for (var n = 0; n < 3; n++) {
        if (!await grab('$name.$n', native: native)) say('no dump for ${sc.id}.$style');
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
      say('fig ${sc.id}.$style${native ? '' : ' (flutter)'}');
    }
  }

  // Every background, under a plain figure; MilkDrop under a spread of its presets.
  final plain = d.scenes.firstWhere((s) => s.id == 'blocks', orElse: () => d.scenes.first).id;
  final milk = MilkFeed.shared;
  final presets = milk.library.presets.where((p) => !milk.library.isOff(p)).toList();
  final rng = math.Random(7);
  for (final g in comboGrounds) {
    if (g == 'black') continue;
    final n = g == 'milk' ? math.min(16, math.max(3, presets.length)) : 3;
    d.play(Combo(ground: g, scene: plain, style: 'raw'));
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    for (var i = 0; i < n; i++) {
      if (g == 'milk' && presets.isNotEmpty) {
        milk.load(presets[rng.nextInt(presets.length)]);
        await Future<void>.delayed(const Duration(milliseconds: 2500));
      }
      if (!await grab('$dir/ground/$g.$i', native: true)) say('no dump for ground $g');
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    say('ground $g');
  }
  await File('$dir/done').writeAsString('${DateTime.now()}\n');
  say('done $dir');
}

/// Every MilkDrop preset the app has, on its own (the MilkDrop scene), held a couple of
/// seconds and written out twice: `<dir>/milk/<n>.<k>.*` and `<dir>/milk/names.json` (the
/// presets' full names by n), then `<dir>/milk/done`. The audit scores how each looks,
/// alone and as a background, and how intense it is.
Future<void> runMilkAudit(DemoShowFeed demo, SceneBook book, String dir) async {
  final stage = NativeStage.instance;
  void say(String s) => stdout.writeln('AUDIT $s');
  if (stage == null) {
    say('no native stage');
    return;
  }
  final out = '$dir/milk';
  await Directory(out).create(recursive: true);
  final milk = MilkFeed.shared;
  final d = demo.director..kinds = {for (final l in book.looks.values) l.id: l.rig.figure.kind};
  // MilkDrop on (its library is read once it is wanted), then nothing changes the
  // preset but the audit (not saved: the hands' setting stays).
  d.play(const Combo(ground: ownGround, scene: 'milk', style: 'raw'));
  await Future<void>.delayed(const Duration(seconds: 4));
  for (var i = 0; i < 240 && (milk.library.presets.isEmpty || !milk.running); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  say('milk ${milk.library.presets.length} presets, running ${milk.running}');
  milk.director.locked = true;
  milk.lock(true);
  final presets = [...milk.library.presets];
  final names = <String, String>{};
  for (final (n, p) in presets.indexed) {
    names['$n'] = p.fullName;
    if (File('$out/$n.1.meta.json').existsSync()) continue;
    if (milk.crashed.contains(p.path)) continue;
    milk.load(p);
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    for (var k = 0; k < 2; k++) {
      final path = '$out/$n.$k';
      final file = File('$path.out');
      if (stage.dump(path)) {
        for (var w = 0; w < 100 && !file.existsSync(); w++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      await File('$path.meta.json').writeAsString('{"native":true,"crashed":${milk.crashed.contains(p.path)}}\n');
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    if (n % 25 == 0) say('milk $n of ${presets.length}');
  }
  await File('$out/names.json').writeAsString(jsonEncode(names));
  await File('$out/done').writeAsString('${DateTime.now()}\n');
  say('done $out');
}
