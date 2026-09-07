import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/swipe.dart';

void main() {
  Widget host({
    VoidCallback? left,
    VoidCallback? right,
    VoidCallback? up,
    VoidCallback? down,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: DragFollow(
              onSwipeLeft: left,
              onSwipeRight: right,
              onSwipeUp: up,
              onSwipeDown: down,
              child: const SizedBox(width: 300, height: 120, child: Text('bar')),
            ),
          ),
        ),
      );

  Offset offsetOf(WidgetTester tester) {
    final transform = tester.widget<Transform>(find.descendant(
      of: find.byType(DragFollow),
      matching: find.byType(Transform),
    ));
    return Offset(transform.transform.getTranslation().x,
        transform.transform.getTranslation().y);
  }

  testWidgets('the content follows the finger while dragging', (tester) async {
    await tester.pumpWidget(host(left: () {}));
    expect(offsetOf(tester), Offset.zero);

    final gesture = await tester.startGesture(tester.getCenter(find.text('bar')));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();

    // The whole point: something moved before the finger lifted.
    expect(offsetOf(tester).dx, lessThan(-10));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a small drag springs back and fires nothing', (tester) async {
    var fired = false;
    await tester.pumpWidget(host(left: () => fired = true));

    final gesture = await tester.startGesture(tester.getCenter(find.text('bar')));
    await gesture.moveBy(const Offset(-12, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(fired, isFalse, reason: 'a nudge must be cancellable');
    expect(offsetOf(tester), Offset.zero, reason: 'and it must return to rest');
  });

  testWidgets('a full drag completes the action', (tester) async {
    var fired = false;
    await tester.pumpWidget(host(left: () => fired = true));

    final gesture = await tester.startGesture(tester.getCenter(find.text('bar')));
    await gesture.moveBy(const Offset(-70, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(fired, isTrue);
    expect(offsetOf(tester), Offset.zero);
  });

  testWidgets('direction is decided once, so a diagonal drag does not jitter',
      (tester) async {
    await tester.pumpWidget(host(left: () {}, up: () {}));
    final gesture = await tester.startGesture(tester.getCenter(find.text('bar')));
    await gesture.moveBy(const Offset(-30, 4));    // mostly horizontal
    await tester.pump();
    await gesture.moveBy(const Offset(-5, 30));    // now mostly vertical
    await tester.pump();

    expect(offsetOf(tester).dy, 0.0,
        reason: 'a gesture that started sideways stays sideways');
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a direction with no handler does not move', (tester) async {
    await tester.pumpWidget(host(left: () {}));    // horizontal only
    final gesture = await tester.startGesture(tester.getCenter(find.text('bar')));
    await gesture.moveBy(const Offset(0, -50));
    await tester.pump();

    expect(offsetOf(tester), Offset.zero,
        reason: 'nothing should slide around for a gesture that does nothing');
    await gesture.up();
    await tester.pumpAndSettle();
  });
}
