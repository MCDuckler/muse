// A list that arrives a page at a time, and what it does while it arrives.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/paged.dart';

void main() {
  test('a refresh keeps what is on screen until the new rows arrive', () async {
    // Clearing first made a refresh a flash of nothing: the list vanished, the scroll
    // jumped to the top, and the same rows came back a moment later — which reads as
    // the app losing your place rather than as it checking.
    var answer = ['a', 'b', 'c'];
    late List<String> seenDuring;
    final paged = Paged<String>(
      pageSize: 3,
      fetch: (offset, limit) async {
        seenDuring = List.of(answer);
        return (items: answer, total: answer.length);
      },
    );

    await paged.next();
    expect(paged.items, ['a', 'b', 'c']);

    answer = ['a', 'b', 'c', 'd'];
    final refreshing = paged.reload();
    expect(paged.items, isNotEmpty,
        reason: 'the old rows are still there while the new ones are asked for');
    await refreshing;
    expect(paged.items, ['a', 'b', 'c', 'd']);
    expect(seenDuring, isNotEmpty);
  });

  test('a refresh asks from the top, not from where the list had got to', () async {
    final asked = <int>[];
    final paged = Paged<int>(
      pageSize: 2,
      fetch: (offset, limit) async {
        asked.add(offset);
        // A server answers with as much as was asked for, which is the part that
        // matters here: a refresh asks for everything that was on screen.
        return (
          items: [for (var i = 0; i < limit; i++) offset + i],
          total: 10,
        );
      },
    );

    await paged.next();
    await paged.next();
    expect(asked, [0, 2]);
    expect(paged.items.length, 4);

    await paged.reload();
    expect(asked.last, 0, reason: 'a refresh is the list again, from its beginning');
    expect(paged.items.length, 4, reason: 'and as much of it as was on screen');
  });

  test('a short page is the end of the list', () async {
    final paged = Paged<int>(
      pageSize: 5,
      fetch: (offset, limit) async => (items: [1, 2], total: 99),
    );
    await paged.next();
    expect(paged.more, isFalse,
        reason: 'what came back is the truth, whatever the total says');
  });
}
