// The pool: switches, leans, the combo table and what the old preferences become.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_pool.dart';
import 'package:muse/src/state/show/show_rig.dart';

void main() {
  test('a switch off, and all of them off is none off', () {
    var p = ShowPool.none.withOff('treatment.contour', true);
    expect(p.isOn('treatment.contour'), isFalse);
    expect(p.isOn('treatment.ascii'), isTrue);
    expect(p.on('treatment', Treatment.values, (t) => t.name), isNot(contains(Treatment.contour)));
    for (final t in Treatment.values) {
      p = p.withOff('treatment.${t.name}', true);
    }
    expect(p.on('treatment', Treatment.values, (t) => t.name), Treatment.values);
    expect(p.withOff('treatment.contour', false).isOn('treatment.contour'), isTrue);
  });

  test('a lean is kept between nought and two', () {
    final p = ShowPool.none.withLean('figure.birds', 5);
    expect(p.leanOf('figure.birds'), 2);
    expect(p.leanOf('figure.dancers'), 1);
  });

  test('the shipped table: plain dancers go over MilkDrop, the rest in contrast, a silhouette not at all', () {
    const p = ShowPool.none;
    const plain = RigFigure(kind: Figure.dancers, shade: Shade.textured);
    expect(p.blendFor(plain, Ground.milk).ground, GroundMode.contrast);
    expect(p.blendFor(plain, Ground.milk).figure, FigureMode.over);
    const ascii = RigFigure(kind: Figure.dancers, shade: Shade.chrome, treatment: Treatment.ascii);
    expect(p.blendFor(ascii, Ground.milk).ground, GroundMode.contrast);
    expect(p.together(ascii, Ground.milk), isTrue);
    const mono = RigFigure(kind: Figure.dancers, shade: Shade.silhouette);
    expect(p.together(mono, Ground.milk), isFalse);
    // On black everything is over, plainly.
    expect(p.blendFor(ascii, Ground.black).ground, GroundMode.over);
    expect(p.together(mono, Ground.black), isTrue);
  });

  test('the hands\' rule comes before the shipped one, and goes again', () {
    const mono = RigFigure(kind: Figure.dancers, shade: Shade.silhouette);
    final key = ShowPool.comboKey(mono, Ground.milk);
    expect(key, 'figure.dancers.shade.silhouette|ground.milk');
    final p = ShowPool.none.withCombo(key, const ComboRule(ground: GroundMode.window));
    expect(p.together(mono, Ground.milk), isTrue);
    expect(p.blendFor(mono, Ground.milk).ground, GroundMode.window);
    expect(p.withCombo(key, null).together(mono, Ground.milk), isFalse);
    // A figure switched off is never together with anything.
    expect(p.withOff('figure.dancers', true).together(mono, Ground.milk), isFalse);
  });

  test('json both ways', () {
    final p = ShowPool.none
        .withOff('look.flash', true)
        .withLean('figure.birds', 1.5)
        .withCombo('figure.birds|ground.milk', ComboRule.never)
        .copyWith(dancer: 'joe', quantise: Quantise.phrase, bias: 0.5);
    final back = ShowPool.fromJson(p.toJson());
    expect(back.off, {'look.flash'});
    expect(back.leanOf('figure.birds'), 1.5);
    expect(back.combos['figure.birds|ground.milk'], ComboRule.never);
    expect(back.dancer, 'joe');
    expect(back.quantise, Quantise.phrase);
    expect(back.bias, 0.5);
    expect(ShowPool.fromJson(const {}).quantise, Quantise.bar);
  });

  test('the tier and the dark beat are kept, and reach the statics', () {
    final p = ShowPool.none.copyWith(tier: 'low', darkBeat: true);
    final back = ShowPool.fromJson(p.toJson());
    expect(back.tier, 'low');
    expect(back.darkBeat, isTrue);
    expect(ShowPool.fromJson(const {'tier': 'ultra'}).tier, 'auto');
    QualityPool.from(back);
    expect(QualityPool.flockK, 0.45);
    expect(QualityPool.bigTroupes, isFalse);
    expect(QualityPool.workScale, 0.6);
    QualityPool.from(ShowPool.none);
    expect(QualityPool.workScale, 1);
  });

  test('the old preferences become switches', () {
    final p = ShowPool.migrated(scenesOff: ['flash', 'veins'], dancersOff: ['joe'], dancer: 'mix');
    expect(p.looksOff, {'flash', 'veins'});
    expect(p.dancersOff, ['joe']);
    expect(p.dancer, isNull);
    expect(p.isOn('treatment.contour'), isFalse);
    expect(ShowPool.migrated(dancer: 'chris').dancer, 'chris');
  });
}
