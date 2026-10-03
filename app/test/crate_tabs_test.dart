// Whether the crate's tabs can wear their names.
//
// They read LIBRAR, SEARO, SIMILA on screen. The tabs share the row equally, so what
// each one has is the row divided by however many there are — five, or six when a
// record is being taken apart — and a Pad clips its word rather than shrinking it. The
// rule was a width: past 470 pixels, wear the names. At 470 with six tabs the longest
// name does not fit by a dozen pixels, so it was cut off instead, and had been for
// anyone whose crate was under about seven hundred.
//
// This is the measurement that replaced the guess, on its own, because a clipped word
// cannot be caught by looking at what a Text says: the string is whole and the paint
// is what is short.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/booth/desk/console_crate.dart';

void main() {
  const all = [
    (CrateTab.queue, 'QUEUE', Icons.queue_music),
    (CrateTab.fits, 'FITS', Icons.compare_arrows),
    (CrateTab.library, 'LIBRARY', Icons.library_music_outlined),
    (CrateTab.search, 'SEARCH', Icons.search),
    (CrateTab.similar, 'SIMILAR', Icons.auto_awesome_outlined),
    (CrateTab.parts, 'PARTS', Icons.call_split),
  ];

  testWidgets('the names are worn only where the longest of them fits',
      (tester) async {
    late BuildContext here;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      here = c;
      return const SizedBox();
    })));

    // The width the old rule allowed them at, with every tab there: LIBRARY and
    // SIMILAR are 69 px of word, and a tab has 92 px for eight of air, thirteen of
    // icon, five of gap and the word — which is 103. It did not fit, and it showed.
    expect(crateWordsFit(here, all, 620), isFalse);
    expect(crateWordsFit(here, all, 470), isFalse,
        reason: 'the old rule said yes here, which is where the clipping came from');

    // Room for them, and they come back.
    expect(crateWordsFit(here, all, 1000), isTrue);

    // One fewer tab is more room each, so the same crate can say them. Six need 687
    // pixels of crate and five need 579, so between the two the answer depends on
    // whether a record is being taken apart — which is exactly the case a fixed width
    // could not know about.
    final five = all.take(5).toList();
    expect(crateWordsFit(here, five, 640), isTrue);
    expect(crateWordsFit(here, all, 640), isFalse,
        reason: 'six tabs in the same row have less each');

    // Nothing sensible to divide: no names rather than a crash.
    expect(crateWordsFit(here, all, 0), isFalse);
    expect(crateWordsFit(here, all, 40), isFalse);
  });

  testWidgets('a bigger text size takes the names away before it cuts them',
      (tester) async {
    // The old rule was a number of pixels, which knows nothing about how big the words
    // are drawn: turn the text size up and the same crate clipped sooner. Measured, the
    // answer moves with the words — at 1.8x, SIMILAR is 120 px rather than 69, and a
    // crate that could say it cannot any more.
    late BuildContext plain, large;
    await tester.pumpWidget(MaterialApp(
      home: Column(children: [
        MediaQuery(
          data: const MediaQueryData(),
          child: Builder(builder: (c) {
            plain = c;
            return const SizedBox();
          }),
        ),
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
          child: Builder(builder: (c) {
            large = c;
            return const SizedBox();
          }),
        ),
      ]),
    ));
    expect(crateWordsFit(plain, all, 900), isTrue);
    expect(crateWordsFit(large, all, 900), isFalse,
        reason: 'the words are nearly twice as wide; the crate is the same');
  });
}
