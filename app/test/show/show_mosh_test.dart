// The datamosh: which changes the director moshes (as many as the pool says, one the
// hands ask for always, never the first scene), and the count carried to the stage in
// the frame and over the wire.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_director.dart';
import 'package:muse/src/state/show/show_pool.dart';
import 'package:muse/src/state/show/show_state.dart';

void main() {
  ShowDirector director() => ShowDirector(scenes: const [SceneMeta(id: 'kinetic'), SceneMeta(id: 'glide'), SceneMeta(id: 'blocks')]);

  test('none by default; the first scene never; every change at a share of 1, cut through', () {
    final d = director();
    d.choose('kinetic');
    d.choose('glide');
    expect(d.moshes, 0);

    final all = director()..moshShare = 1;
    all.choose('kinetic');
    expect(all.moshes, 0, reason: 'nothing on to mosh from');
    all.choose('glide');
    expect(all.moshes, 1);
    final st = ShowState(now: DateTime(2026), a: const ShowDeck(name: 'A'), b: const ShowDeck(name: 'B'));
    final r = all.direct(st, const []);
    expect(r.k, 1, reason: 'a mosh is a cut the stage moshes, not a dissolve');
    // The same scene again is no change at all.
    all.choose('glide');
    expect(all.moshes, 1);
  });

  test('the hands\' MOSH whatever the share', () {
    final d = director();
    d.choose('kinetic');
    d.next(how: SceneChange.mosh);
    expect(d.moshes, 1);
    expect(d.scene, 'glide');
  });

  test('the share kept in the pool; the count in the frame, over the wire', () {
    expect(ShowPool.fromJson(const {}).mosh, ShowPool.defaultMosh);
    expect(ShowPool.fromJson(jsonDecode(jsonEncode(const ShowPool(mosh: 0.8).toJson())) as Map<String, dynamic>).mosh, 0.8);
    final st = ShowState(now: DateTime(2026), a: const ShowDeck(name: 'A'), b: const ShowDeck(name: 'B')).copyWith(mosh: 3);
    expect(ShowState.fromJson(jsonDecode(jsonEncode(st.toJson())) as Map<String, dynamic>).mosh, 3);
    expect(st.advanced(0.1).mosh, 3);
  });
}
