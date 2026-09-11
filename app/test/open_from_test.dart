// The player opening out of the small bar, and closing back into it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/open_from.dart';

void main() {
  const bar = Rect.fromLTWH(8, 700, 384, 72);
  final page = Container(key: const ValueKey('page'), color: const Color(0xFF102030));

  Future<void> show(WidgetTester tester, double t) async {
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(400, 800)),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: OpenFrom(
          animation: AlwaysStoppedAnimation<double>(t),
          from: bar,
          child: page,
        ),
      ),
    ));
  }

  testWidgets('it starts as the bar it was tapped on', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await show(tester, 0);
    final window = tester.getRect(find.byType(ClipRRect));
    expect(window, bar, reason: 'the page is only visible where the bar was');
  });

  testWidgets('it ends as the whole screen', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await show(tester, 1);
    expect(find.byType(ClipRRect), findsNothing,
        reason: 'nothing is left over the page once it has arrived');
    expect(tester.getRect(find.byKey(const ValueKey('page'))),
        const Rect.fromLTWH(0, 0, 400, 800));
  });

  testWidgets('half way it is between the two, still page-shaped', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await show(tester, 0.5);
    final window = tester.getRect(find.byType(ClipRRect));
    expect(window.width, greaterThan(bar.width));
    expect(window.width, lessThan(400));
    expect(window.bottom, greaterThan(bar.top));
    // The page inside keeps its full size — it is seen through a window, not
    // squashed into one, so nothing about it is stretched on the way.
    expect(tester.getSize(find.byKey(const ValueKey('page'))),
        const Size(400, 800));
  });

  testWidgets('with nowhere to come from it rises from the bottom edge',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(400, 800)),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: OpenFrom(
          animation: const AlwaysStoppedAnimation<double>(0.5),
          child: page,
        ),
      ),
    ));
    final at = tester.getRect(find.byKey(const ValueKey('page')));
    expect(at.top, greaterThan(0), reason: 'still on its way up');
    expect(at.size, const Size(400, 800));
  });
}
