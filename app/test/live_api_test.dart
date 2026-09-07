@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/client.dart';

/// Exercises the real client against a running muse server. Skipped when there
/// isn't one, so `flutter test` stays green on a machine without the stack up.
///   MUSE_TEST_SERVER=http://127.0.0.1:8770 MUSE_TEST_USER=chris MUSE_TEST_PASS=devpass
void main() {
  final base = Platform.environment['MUSE_TEST_SERVER'];
  final user = Platform.environment['MUSE_TEST_USER'];
  final pass = Platform.environment['MUSE_TEST_PASS'];

  if (base == null || user == null || pass == null) {
    test('live api', () {}, skip: 'set MUSE_TEST_SERVER/USER/PASS to run');
    return;
  }

  late ApiClient api;

  setUpAll(() async {
    api = ApiClient(baseUrl: base);
    await api.login(user, pass, 'flutter-test');
  });

  test('login yields a working token', () async {
    final me = await api.me();
    expect(me['user'], user);
  });

  test('wrong password is reported as 401, not a crash', () async {
    final bad = ApiClient(baseUrl: base);
    expect(
      () => bad.login(user, 'definitely-not-it', 'flutter-test'),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
    );
  });

  test('search returns local hits and flags known remote ones', () async {
    final res = await api.search('Get Lucky');
    expect(res.local, isNotEmpty);
    expect(res.local.first.title.toLowerCase(), contains('lucky'));
    final known = res.remote.where((r) => r.known);
    expect(known.length, greaterThanOrEqualTo(1),
        reason: 'the library already has this one, so it must be marked');
  });

  test('resolving a cached track comes back ready, not queued', () async {
    final t = await api.resolve(videoId: 'Rgrt_8mXrK8');
    expect(t.isReady, isTrue);
    expect(t.streamPath, '/tracks/${t.id}/stream');
    expect(t.gainDb, isNotNull, reason: 'loudness is measured at ingest');
  });

  test('a queue round-trips through create, fill, cursor and conflict', () async {
    final name = 'flutter-test-${DateTime.now().millisecondsSinceEpoch}';
    final made = await api.createQueue(name);
    final track = await api.resolve(videoId: 'Rgrt_8mXrK8');

    final filled = await api.replaceQueue(made.id, made.rev, [track.id]);
    expect(filled.items.single.id, track.id);
    expect(filled.rev, made.rev + 1);

    await api.setCursor(made.id, index: 0, positionMs: 12000);
    final read = await api.queue(made.id);
    expect(read.positionMs, 12000);
    expect(read.rev, filled.rev, reason: 'the cursor must not bump rev');

    // A stale write surfaces as a conflict carrying the live state to merge from.
    await expectLater(
      () => api.replaceQueue(made.id, made.rev, []),
      throwsA(isA<QueueConflict>()),
    );
  });

  test('the stream endpoint serves ranges to the player', () async {
    final t = await api.resolve(videoId: 'Rgrt_8mXrK8');
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(api.streamUrl(t)));
    api.streamHeaders.forEach(req.headers.set);
    req.headers.set('Range', 'bytes=0-1023');
    final res = await req.close();
    expect(res.statusCode, 206);
    expect(res.headers.value('content-range'), matches(r'bytes 0-1023/\d+'));
    await res.drain();
    client.close();
  });
}
