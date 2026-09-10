// Artwork kept on the device.
//
// The whole benefit rests on one thing: the name a picture is filed under has to be
// the same next time. The URLs carry a signing key that changes every session, so
// keying on the whole address would file every cover under a new name each time the
// app signed in — a cache that fills up and never once hits, which looks exactly like
// a cache that is working.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/art_cache.dart';

void main() {
  test('the session key is not part of the name', () {
    const a = 'https://box/tracks/12/cover?size=sm&v=ab12cd34&k=SESSION-ONE';
    const b = 'https://box/tracks/12/cover?size=sm&v=ab12cd34&k=SESSION-TWO';
    expect(ArtCache.keyFor(a), ArtCache.keyFor(b));
  });

  test('but everything that identifies the picture is', () {
    const base = 'https://box/tracks/12/cover?size=sm&v=ab12cd34';
    final names = {
      ArtCache.keyFor(base),
      ArtCache.keyFor('$base&style=jacket&r=4'),
      ArtCache.keyFor('$base&style=disc&r=4'),
      // A new render of the same artwork is a different picture.
      ArtCache.keyFor('$base&style=jacket&r=5'),
      // So is the same track's art after it changed.
      ArtCache.keyFor('https://box/tracks/12/cover?size=sm&v=ffffffff'),
      // So is a different size, and a different track.
      ArtCache.keyFor('https://box/tracks/12/cover?size=lg&v=ab12cd34'),
      ArtCache.keyFor('https://box/tracks/13/cover?size=sm&v=ab12cd34'),
    };
    expect(names.length, 7, reason: 'each of those is its own file');
  });

  test('the name is usable as a filename', () {
    final name = ArtCache.keyFor(
        'https://box/tracks/12/cover?size=sm&v=ab12cd34&style=jacket&k=a/b+c=');
    expect(name, matches(RegExp(r'^[A-Za-z0-9_]+$')));
    expect(name.length, lessThan(120));
  });
}
