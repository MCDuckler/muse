// The pool's splitter, from this computer's side: parts made here before the pool
// existed are handed in once, and never twice.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/worker/splitter.dart';

class _House implements SplitServer {
  final claimed = <int>[];
  final handedIn = <int, Set<String>>{};

  /// Records the house already has, or another computer is doing: nothing to claim.
  final taken = <int>{};

  @override
  String get house => 'http://example.invalid';
  @override
  Future<SplitJob?> claim(int trackId) async {
    claimed.add(trackId);
    return taken.contains(trackId) ? null : SplitJob(id: trackId * 10, trackId: trackId, own: true);
  }

  @override
  Future<void> handIn(SplitJob job, Map<String, File> parts, {double? seconds}) async =>
      handedIn[job.trackId] = parts.keys.toSet();
  @override
  Future<void> fetchRecord(int trackId, File into,
      {void Function(int got, int? total)? progress}) async {}
  @override
  Future<void> fail(SplitJob job, String reason, {required bool retryable}) async {}
  @override
  Future<List<SplitJob>> lease({required Map<String, dynamic> pool, int wait = 25}) async => [];
  @override
  Future<void> progress(SplitJob job, String stage, double? percent) async {}
  @override
  Future<void> release(SplitJob job) async {}
}

void main() {
  test('parts made here before are handed in once', () async {
    final folder = Directory.systemTemp.createTempSync('muse-split-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final stems = Directory('${folder.path}/stems')..createSync();
    for (final p in splitParts) {
      File('${stems.path}/7-$p-v2.m4a').writeAsBytesSync([1]);
      File('${stems.path}/8-$p-v2.m4a').writeAsBytesSync([1]);
    }
    File('${stems.path}/9-drums-v1.m4a').writeAsBytesSync([1]); // the old arithmetic: not shared
    final house = _House()..taken.add(8);
    final s = Splitter(
        server: house,
        appFolder: folder,
        findFfmpeg: () async => null,
        pool: () => const {});
    await s.shareWhatIsHere();
    expect(house.handedIn, {7: splitParts.toSet()});
    expect(house.claimed.toSet(), {7, 8}, reason: '8 the house had: asked, not sent');
    expect(s.shared, 1);

    house.claimed.clear();
    await s.shareWhatIsHere();
    expect(house.claimed, isEmpty, reason: 'each record is asked about once');
  });
}
