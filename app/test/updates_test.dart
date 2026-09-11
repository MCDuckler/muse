// Whether the app on the server is newer than the one in your hand.
//
// The version this replaces was a constant in the source that had said 0.1.0 since the
// first commit, so nothing could ever have told a new APK from the running one. The
// answer is now a build stamp, and the whole of the update feature rests on this
// comparison being right in both directions: never missing a new version, and never
// claiming one that is not there.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/updates.dart';

Release at(String build, {int bytes = 1000}) =>
    Release(version: '0.1.0', build: build, bytes: bytes);

void main() {
  test('a later stamp is a newer app', () {
    expect(at('202609111200').isNewerThan('202609110900'), isTrue);
    expect(at('202610010000').isNewerThan('202609302359'), isTrue);
  });

  test('the same build is not an update', () {
    expect(at('202609111200').isNewerThan('202609111200'), isFalse);
  });

  test('an older one on the server is not an update either', () {
    // Which happens: the web app and the APK are published separately, and somebody
    // installing an APK built after the last publish should not be told to go back.
    expect(at('202609110900').isNewerThan('202609111200'), isFalse);
  });

  test('a build that does not know when it was made can still be updated', () {
    // Every copy installed by hand before any of this existed is one of these, and
    // refusing them was a trap with no way out: the first stamped build could not be
    // reached from an unstamped one, so the feature could not install the version that
    // makes the feature work.
    expect(at('202609111200').isNewerThan(''), isTrue);
    expect(at('202609111200').isNewerThan('not-a-stamp'), isTrue);
    expect(Release.knows(''), isFalse, reason: 'and it says so on the screen');
    expect(Release.knows('202609111200'), isTrue);
  });

  test('and neither is a server that says nothing useful', () {
    expect(at('').isNewerThan('202609110900'), isFalse);
    expect(at('unknown').isNewerThan('202609110900'), isFalse);
  });

  test('what it reads is what the publisher writes', () {
    final r = Release.fromJson({
      'version': '0.2.0',
      'build': '202609111200',
      'bytes': 62_914_560,
      'built': '2026-09-11T12:00:00Z',
    });
    expect(r.version, '0.2.0');
    expect(r.build, '202609111200');
    expect(r.size, '60.0 MB');
  });

  test('a manifest missing everything does not throw', () {
    final r = Release.fromJson(const {});
    expect(r.build, '');
    expect(r.isNewerThan('202609110900'), isFalse);
  });
}
