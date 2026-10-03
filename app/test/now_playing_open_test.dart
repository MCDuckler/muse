// Opening and closing the player with a finger: the drag *is* the animation.
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/now_playing.dart';

void main() {
  late NavigatorState navigator;

  Future<NowPlayingRoute> open(WidgetTester tester, {bool byHand = true}) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        navigator = Navigator.of(context);
        return const Scaffold(body: Text('home'));
      }),
    ));
    final route = NowPlayingRoute(
      from: const Rect.fromLTWH(8, 700, 384, 72),
      byHand: byHand,
      page: (_) => const ColoredBox(color: Color(0xFF223344)),
    );
    navigator.push(route);
    await tester.pump();
    return route;
  }

  testWidgets('a drag that is still happening has not opened anything yet',
      (tester) async {
    final route = await open(tester);
    expect(route.hand!.value, 0,
        reason: 'pushed and held still: the finger says how far from here');

    final hold = NowPlayingHold(route);
    hold.moveBy(0.3);
    await tester.pump();
    expect(route.hand!.value, closeTo(0.3, 0.001),
        reason: 'a third of a screen of finger is a third of the way open');

    hold.letGo(2.5);                       // thrown at the screen
    await tester.pumpAndSettle();
    expect(route.hand!.value, 1);
    expect(find.text('home'), findsNothing, reason: 'the player is over it');
  });

  testWidgets('letting go on the way up puts it back, and takes the route with it',
      (tester) async {
    final route = await open(tester);
    final hold = NowPlayingHold(route);
    hold.moveBy(0.22);
    await tester.pump();

    hold.letGo(0);                         // let go without throwing, barely up
    await tester.pumpAndSettle();
    expect(route.isActive, isFalse,
        reason: 'a route left at nothing is invisible and in front of everything');
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('dragging it shut runs the same animation backwards', (tester) async {
    final route = await open(tester, byHand: false);
    await tester.pumpAndSettle();
    expect(route.hand!.value, 1);

    final hold = NowPlayingHold(route);
    hold.moveBy(-0.3);
    await tester.pump();
    expect(route.hand!.value, closeTo(0.7, 0.001));

    hold.moveBy(0.3);
    await tester.pump();
    expect(route.hand!.value, 1, reason: 'and changing your mind is allowed');

    NowPlayingHold(route).letGo(-2.5);     // flicked down
    await tester.pumpAndSettle();
    expect(route.isActive, isFalse);
    expect(find.text('home'), findsOneWidget);
  });
  testWidgets('on Android the player is simply there, with nothing in between',
      (tester) async {
    // Reported as a wipe-up that takes too long and lags. What it costs is a
    // screen-sized rounded clip with a blurred shadow under it and a cross-fade inside
    // it, every frame for a third of a second, over the busiest page in the app — and
    // what anybody wants from tapping the bar is the player, not a performance of the
    // player arriving.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(NowPlayingRoute.plainly, isTrue);
    final route = NowPlayingRoute(from: const Rect.fromLTWH(0, 700, 400, 64));
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);

    late BuildContext anywhere;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      anywhere = c;
      return const SizedBox();
    })));
    const page = SizedBox.shrink();
    expect(
        identical(
            route.buildTransitions(anywhere, const AlwaysStoppedAnimation(0.5),
                const AlwaysStoppedAnimation(0), page),
            page),
        isTrue,
        reason: 'no window, no clip, no shadow — the page itself, half way through');
    // Put back inside the body: the framework checks for a changed debug variable
    // before a tearDown would get to it.
    debugDefaultTargetPlatformOverride = null;
  });

}
