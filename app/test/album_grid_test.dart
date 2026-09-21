// How many covers go across the wall of records.
//
// Left alone it fits what sits comfortably, exactly as before anyone could choose.
// Asked for a number it gives that number, short of making covers too small to be
// covers — and once they are too small to write under, it stops writing under them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/album_grid.dart';

void main() {
  test('left alone, a phone gets two and a desk gets as many as fit', () {
    final phone = AlbumGrid.of(usable: 376, wide: false);
    expect(phone.across, 2);
    expect(phone.captions, isTrue);
    // What the grid used to be told: tiles no wider than 190 at 0.74 of their height.
    expect(phone.extent, closeTo(phone.tile / 0.74, 0.5));

    final desk = AlbumGrid.of(usable: 1500, wide: true);
    expect(desk.across, 7);
    expect(desk.tile, lessThanOrEqualTo(230));
  });

  test('asked for a number, it is that number', () {
    final four = AlbumGrid.of(usable: 376, wide: false, chosen: 4);
    expect(four.across, 4);
    expect(four.tile * 4 + four.gapAcross * 3, closeTo(376, 0.01));
  });

  test('a phone asked for more than it can show gets the most it can', () {
    final many = AlbumGrid.of(usable: 376, wide: false, chosen: 12);
    expect(many.across, AlbumGrid.mostAcross(376));
    expect(many.tile, greaterThanOrEqualTo(70));
  });

  test('small covers lose the writing under them, and the room it took', () {
    final five = AlbumGrid.of(usable: 376, wide: false, chosen: 5);
    expect(five.captions, isFalse);
    expect(five.extent, five.tile);
  });

  test('type under a cover keeps the room type needs, however small the cover', () {
    final three = AlbumGrid.of(usable: 376, wide: false, chosen: 3, textScale: 1.6);
    expect(three.captions, isTrue);
    expect(three.extent - three.tile, greaterThan(8 + 40 * 1.6 - 0.01));
  });

  // The sums have to be the grid's own, because the letter rail turns "record 1,640"
  // into pixels with them.
  testWidgets('the stride is where the grid really puts the next row', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final grid = AlbumGrid.of(usable: 376, wide: false, chosen: 3);
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: grid.across,
          mainAxisExtent: grid.extent,
          crossAxisSpacing: grid.gapAcross,
          mainAxisSpacing: grid.gapDown,
        ),
        itemCount: 9,
        itemBuilder: (context, i) => SizedBox(key: ValueKey(i)),
      ),
    ));
    final first = tester.getTopLeft(find.byKey(const ValueKey(0)));
    final nextRow = tester.getTopLeft(find.byKey(const ValueKey(3)));
    expect(nextRow.dy - first.dy, closeTo(grid.stride, 0.01));
    expect(tester.getSize(find.byKey(const ValueKey(0))).width, closeTo(grid.tile, 0.01));
  });
}
