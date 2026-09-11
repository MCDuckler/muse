// Folding a burst of reports into one.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/coalesce.dart';

void main() {
  test('the first one goes straight through', () {
    var runs = 0;
    final fold = Coalesce(const Duration(milliseconds: 100), () => runs++);
    fold();
    expect(runs, 1, reason: 'waiting to say the first thing is a stall');
    fold.dispose();
  });

  testWidgets('a burst becomes one call at the end of the window',
      (tester) async {
    var runs = 0;
    final fold = Coalesce(const Duration(milliseconds: 100), () => runs++);
    fold();
    for (var i = 0; i < 40; i++) {
      fold();
      await tester.pump(const Duration(milliseconds: 5));
    }
    // 200ms of calls at 5ms apart: one immediately, then one per window.
    expect(runs, lessThanOrEqualTo(3));
    expect(runs, greaterThanOrEqualTo(2), reason: 'and nothing is dropped');
    fold.dispose();
  });

  testWidgets('nothing runs after it is disposed', (tester) async {
    var runs = 0;
    final fold = Coalesce(const Duration(milliseconds: 50), () => runs++);
    fold();
    fold();
    fold.dispose();
    await tester.pump(const Duration(milliseconds: 200));
    expect(runs, 1, reason: 'the queued one belongs to a screen that is gone');
  });
}
