// The 3D type: what the hands say of it (kept, read back, the record's words in a
// line), its line as a distance field, and its frame's numbers for either stage.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_pool.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/state/show/show_state.dart';
import 'package:muse/src/ui/show/show_type3d.dart';

ShowState _frame({TypeSpec spec = TypeSpec.standard, double kick = 0}) => ShowState(
      now: DateTime(2026),
      a: const ShowDeck(name: 'A', title: 'Rails', artist: 'Owl', bpm: 128, playing: true, beatIndex: 9, beatPhase: 0.25, barIndex: 2, beatInBar: 1),
      b: const ShowDeck(name: 'B'),
      macros: ShowMacros(type3d: spec),
    );

double _decode(Uint8List rgba, int w, int x, int y) {
  final o = (y * w + x) * 4;
  return (rgba[o] * 256 + rgba[o + 1]) / 65535;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the hands\' words, face, motions and knobs: kept and read back; never nothing', () {
    const spec = TypeSpec(
      lines: ['HELLO', '{artist} — {title}', ''],
      font: TypeFont.orbitron,
      motions: {TypeMotion.flip, TypeMotion.zoom},
      looks: {TypeLook.neon, TypeLook.glass},
      deforms: {TypeDeform.stack, TypeDeform.melt},
      turn: TypeTurn.glitch,
      colour: TypeColour.ice,
      change: TypeChange.bar,
      size: 1.5,
      beat: 2,
    );
    final back = TypeSpec.fromJson(jsonDecode(jsonEncode(spec.toJson())));
    expect(back, spec);
    expect(spec.lineAt(0), 'HELLO');
    expect(spec.lineAt(1, title: 'Rails', artist: 'Owl'), 'Owl — Rails');
    expect(spec.lineAt(2), 'HELLO', reason: 'an empty line is passed over');
    expect(const TypeSpec(lines: ['{title}']).lineAt(0), 'WETOWL', reason: 'nothing to say: the name');
    // A document with nothing, or nonsense, of it: as shipped; knobs kept in reach.
    expect(TypeSpec.fromJson(null), TypeSpec.standard);
    final odd = TypeSpec.fromJson({'motions': <String>[], 'size': 99, 'font': 'nope'});
    expect(odd.motions, TypeSpec.standard.motions);
    expect(odd.size, TypeSpec.knobRange.$2);
    expect(odd.font, TypeFont.bebas);
    // No bends is a choice: the letters as cut.
    expect(TypeSpec.fromJson({'deforms': <String>[]}).deforms, isEmpty);
    // Kept in the pool, carried on the frame.
    final pool = ShowPool.fromJson(ShowPool.none.copyWith(type3d: spec).toJson());
    expect(pool.type3d, spec);
    expect(ShowMacros.fromJson(ShowMacros(type3d: spec).toJson()).type3d, spec);
    expect(ShowPool.none.toJson().containsKey('type3d'), isFalse);
  });

  test('a line as a distance field: the letters under the edge, round them over it', () async {
    final f = await TypeField.bake('I', TypeFont.bebas);
    expect(f.w, greaterThan(f.h ~/ 2));
    expect(f.rgba.length, f.w * f.h * 4);
    // The middle of the I is inside it; the corner of the picture far outside.
    expect(_decode(f.rgba, f.w, f.w ~/ 2, f.h ~/ 2), lessThan(0.4));
    expect(_decode(f.rgba, f.w, 2, 2), greaterThan(0.95));
    // A line of type is one high; the picture its padding more.
    expect(f.halfY, greaterThan(0.5));
    expect(f.range, greaterThan(0));
  });

  test('the frame\'s numbers: as many as the shader declares; the field up on the native stage as it comes on', () async {
    final sent = <String>[];
    final sim = Type3dSim(upload: (name, w, h, rgba) => sent.add(name));
    var v = sim.native(_frame(), 1 / 60, 1280, 720);
    expect(v.length, Type3dParams.length);
    // The field is set off the frame: none up yet, the letters not grown.
    expect(sent, isEmpty);
    await sim.settled();
    v = sim.native(_frame(), 1 / 60, 1280, 720);
    expect(sent, ['type3d.sdf']);
    expect(sim.field?.text, 'WETOWL');
    // The camera well in front, the letters' half size and the look set.
    expect(v[Type3dParams.at['uPos']! + 2], lessThan(-2));
    expect(v[Type3dParams.at['uHalf']!], greaterThan(0));
    // The rows of a turn: unit long.
    final rx = Type3dParams.at['uRotX']!;
    expect(v[rx] * v[rx] + v[rx + 1] * v[rx + 1] + v[rx + 2] * v[rx + 2], closeTo(1, 1e-5));
    final mirror = Type3dParams.at['uMirror']!;
    expect(v[mirror].abs(), 1);
    // Another line asked for: set, then flipped to.
    sim.native(_frame(spec: const TypeSpec(lines: ['OWL'], motions: {TypeMotion.still})), 1 / 60, 1280, 720);
    await sim.settled();
    for (var i = 0; i < 60; i++) {
      sim.native(_frame(spec: const TypeSpec(lines: ['OWL'], motions: {TypeMotion.still})), 1 / 60, 1280, 720);
    }
    expect(sim.field?.text, 'OWL');
    expect(sent, ['type3d.sdf', 'type3d.sdfb']);
    sim.dispose();
  });

  test('the floats are the shader\'s, in its order (both stages set them so)', () {
    final declared = <(String, int)>[
      for (final m in RegExp(r'^uniform (float|vec2|vec3|vec4) (\w+);', multiLine: true).allMatches(File('shaders/show/sim/type3d.frag').readAsStringSync()))
        (m.group(2)!, switch (m.group(1)) { 'vec2' => 2, 'vec3' => 3, 'vec4' => 4, _ => 1 }),
    ];
    expect(Type3dParams.uniforms, declared);
  });

  test('two lines: the next set ahead, turned to on its moment; the bends a phrase picks are the hands\'', () async {
    final sent = <String>[];
    final sim = Type3dSim(upload: (name, w, h, rgba) => sent.add(name));
    const spec = TypeSpec(lines: ['ONE', 'TWO'], change: TypeChange.bar, deforms: {TypeDeform.melt, TypeDeform.ripple, TypeDeform.repeat}, turn: TypeTurn.morph);
    ShowState at(int beat) => ShowState(
          now: DateTime(2026),
          a: ShowDeck(name: 'A', bpm: 120, playing: true, beatIndex: beat, beatPhase: 0, barIndex: beat ~/ 4, beatInBar: beat % 4),
          b: const ShowDeck(name: 'B'),
          macros: const ShowMacros(type3d: spec),
        );
    sim.native(at(0), 1 / 60, 1280, 720);
    await sim.settled();
    sim.native(at(0), 1 / 60, 1280, 720);
    expect(sim.field?.text, 'ONE');
    // The next was made before its bar: on the bar the turn starts at once.
    sim.native(at(4), 1 / 60, 1280, 720);
    expect(sim.turning, isTrue);
    expect(sent, ['type3d.sdf', 'type3d.sdfb'], reason: 'the next line into the other slot');
    final mixAt = Type3dParams.at['uMix']!;
    final v = sim.native(at(4), 0.25, 1280, 720);
    expect(v[mixAt], inExclusiveRange(0, 1), reason: 'half way through the morph');
    for (var i = 0; i < 60; i++) {
      sim.native(at(5), 1 / 60, 1280, 720);
    }
    expect(sim.turning, isFalse);
    expect(sim.field?.text, 'TWO');
    // Two of the hands' bends a phrase; none that are not theirs.
    expect(sim.bends.length, 2);
    expect(spec.deforms.containsAll(sim.bends), isTrue);
    sim.dispose();
  });

  test('the 3D type is a scene with the treatments for styles', () {
    expect(stylesOfFigure(Figure.type3d), ['raw', ...treatmentStyles]);
    expect(ownStyle(Figure.type3d), isFalse);
  });
}
