// The wait, as a field of spinners — and the one in the middle not moving.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/loading.dart';

void main() {
  const screen = Size(400, 800);

  Future<void> show(WidgetTester tester, Widget body) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: body)));
  }

  testWidgets('the one in the middle is where the only one used to be',
      (tester) async {
    await show(tester, const Center(child: CircularProgressIndicator()));
    final alone = tester.getCenter(find.byType(CircularProgressIndicator));

    await show(tester, const LoadingField());
    await tester.pump();
    final first = tester.getCenter(find.byType(CircularProgressIndicator).first);
    expect(first, alone,
        reason: 'the lattice is built out from the centre, so nothing shifts when '
            'the rest of it arrives');
  });

  testWidgets('the rings arrive one after another', (tester) async {
    await show(tester, const LoadingField());
    await tester.pump();
    final atFirst = tester.widgetList(find.byType(CircularProgressIndicator)).length;
    expect(atFirst, 1, reason: 'the middle one, and only that one, on frame one');

    await tester.pump(const Duration(milliseconds: 150));
    final afterOne = tester.widgetList(find.byType(CircularProgressIndicator)).length;
    expect(afterOne, greaterThan(atFirst));

    await tester.pump(const Duration(milliseconds: 500));
    final all = tester.widgetList(find.byType(CircularProgressIndicator)).length;
    expect(all, greaterThan(afterOne), reason: 'and outwards from there');

    // A diamond: as many across as down, around a middle one.
    expect(all, greaterThanOrEqualTo(13));
  });

  testWidgets('nothing is cut off by the edge of the screen', (tester) async {
    await show(tester, const LoadingField());
    await tester.pump(const Duration(seconds: 1));
    for (final spinner in find.byType(CircularProgressIndicator).evaluate()) {
      final at = tester.getRect(find.byWidget(spinner.widget).first);
      expect(at.left, greaterThanOrEqualTo(0));
      expect(at.top, greaterThanOrEqualTo(0));
      expect(at.right, lessThanOrEqualTo(screen.width));
      expect(at.bottom, lessThanOrEqualTo(screen.height));
    }
  });
}
