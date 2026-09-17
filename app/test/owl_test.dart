// The bird a song gets when it has no cover.
//
// There is nothing to assert about how it looks — that was checked by drawing a sheet
// of them and looking — so what is checked here is what a test can know: that it paints
// at the sizes it is used at, and that two songs do not get the same face.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/owl.dart';

void main() {
  testWidgets('it paints at a list row and at a full screen', (tester) async {
    for (final size in [16.0, 44.0, 220.0, 480.0]) {
      await tester.pumpWidget(MaterialApp(
        home: Center(child: GoofyOwl(seed: 12345, size: size)),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'at $size');
    }
  });

  testWidgets('a song with no id at all still gets a bird', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Center(child: GoofyOwl(seed: owlSeed(null), size: 44)),
    ));
    expect(tester.takeException(), isNull);
  });

  test('the same song always gets the same one, and different songs differ', () {
    expect(owlSeed('Get Lucky'), owlSeed('Get Lucky'));
    expect(owlSeed('Get Lucky'), isNot(owlSeed('Around the World')));
    expect(owlSeed(''), owlSeed(null), reason: 'nothing to go on is still a bird');
  });
}
