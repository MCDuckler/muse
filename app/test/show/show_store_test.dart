// The show's document: what it keeps, and a store that forgets.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/state/show/show_pool.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/state/show/show_store.dart';

void main() {
  test('a document comes back whole', () async {
    const rig = ShowRig(ground: RigGround.milk, figure: RigFigure(kind: Figure.birds, treatment: Treatment.ascii));
    final doc = ShowDoc(
      pool: ShowPool.none.withPlan(ShowPlan.shipped.withScene('flash', muted: true)),
      looks: const [Look(id: 'mine', name: 'Mine', rig: rig, hero: true)],
      lastRig: rig,
      panel: const {'tab': 'dancers', 'split': 0.4},
    );
    final store = MemoryShowStore();
    expect(await store.load(), isNull);
    await store.save(doc);
    final back = (await store.load())!;
    expect(back.pool.plan.sceneLevel('flash'), 0);
    expect(back.looks.single.id, 'mine');
    expect(back.looks.single.hero, isTrue);
    expect(back.looks.single.rig, rig);
    expect(back.lastRig, rig);
    expect(back.panel['tab'], 'dancers');
    expect(store.saves, 1);
  });

  test('the old preferences are taken in where there is no document', () async {
    SharedPreferences.setMockInitialValues({
      'muse.show.scenesOff': ['flash', 'veins'],
      'muse.show.dancersOff': ['joe'],
      'muse.show.dancer': 'chris',
    });
    final doc = await migratedShowDoc();
    expect(doc.pool.plan.sceneLevel('flash'), 0);
    expect(doc.pool.plan.sceneLevel('veins'), 0);
    expect(doc.pool.dancersOff, ['joe']);
    expect(doc.pool.dancer, 'chris');
    SharedPreferences.setMockInitialValues({});
    expect((await migratedShowDoc()).pool.plan, ShowPlan.shipped);
  });

  test('an empty document is the shipped state', () {
    final doc = ShowDoc.fromJson(const {'v': 1});
    expect(doc.pool.off, isEmpty);
    expect(doc.looks, isEmpty);
    expect(doc.lastRig, isNull);
  });
}
