// The player opening out of the small bar, and closing back into it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/now_playing.dart';
import 'package:muse/src/ui/open_from.dart';

void main() {
  morph();
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
    expect(tester.getRect(find.byKey(const ValueKey('page'))),
        const Rect.fromLTWH(0, 0, 400, 800),
        reason: 'and it is already laid out where it will finally sit');
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

  testWidgets('half way the window is between the two and the page has not moved',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await show(tester, 0.5);
    final window = tester.getRect(find.byType(ClipRRect));
    expect(window.width, greaterThan(bar.width));
    expect(window.width, lessThan(400));
    expect(window.bottom, greaterThan(bar.top));
    // The page is where it will end up from the first frame: seen through a window
    // rather than squashed into one and dragged into place. Everything on it holds
    // still — including the row of controls along the bottom of the screen, which is
    // the same row the page underneath is showing.
    expect(tester.getRect(find.byKey(const ValueKey('page'))),
        const Rect.fromLTWH(0, 0, 400, 800));
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

// The page arriving over the bar rather than replacing it, and what letting go means.
void morph() {
  testWidgets('the page comes up through the bar rather than covering it at once',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Future<double> opacityAt(double t) async {
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(size: Size(400, 800)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: OpenFrom(
            animation: AlwaysStoppedAnimation<double>(t),
            from: const Rect.fromLTWH(8, 700, 384, 72),
            child: Container(color: const Color(0xFF102030)),
          ),
        ),
      ));
      return tester.widget<Opacity>(find.byType(Opacity)).opacity;
    }

    expect(await opacityAt(0), 0,
        reason: 'at the start the window is the bar, and the bar is what is in it');
    final early = await opacityAt(0.1);
    expect(early, greaterThan(0));
    expect(early, lessThan(1), reason: 'still coming up through it');
    expect(await opacityAt(0.6), 1, reason: 'and fully arrived before it lands');
  });

  test('a flick decides it, however far the drag got', () {
    // Thrown at the screen from a third of the way up: it opens.
    expect(NowPlayingHold.opens(at: 0.3, velocity: 2.5), isTrue);
    // Thrown back down from most of the way open: it shuts.
    expect(NowPlayingHold.opens(at: 0.8, velocity: -2.5), isFalse);
    // Let go of without throwing: wherever it got to decides.
    expect(NowPlayingHold.opens(at: 0.6, velocity: 0), isTrue);
    expect(NowPlayingHold.opens(at: 0.2, velocity: 0), isFalse);
  });
}
