// A station is a queue that keeps going, so what matters here is when it is asked for
// more — a queue nearly finished asked twice a second would be a download every time.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/models.dart';

void main() {
  slices();
  Queue queue({String? station, int items = 20}) => Queue.fromJson({
        'id': 1,
        'name': 'Song radio',
        'cursor_index': 0,
        'position_ms': 0,
        'rev': 1,
        if (station != null) 'station': {'kind': station, 'name': 'Song radio'},
        'items': [
          for (var i = 0; i < items; i++)
            {'id': i + 1, 'title': 'Song $i', 'artists': const ['A'],
             'state': 'ready', 'source': 'youtube', 'pos': i},
        ],
      });

  test('a queue says whether it is a station', () {
    expect(queue().isStation, isFalse);
    expect(queue(station: 'track').isStation, isTrue);
    expect(queue(station: 'album').stationKind, 'album');
  });

  test('a station carries its songs like any other queue', () {
    final q = queue(station: 'artist');
    expect(q.items, hasLength(20));
    expect(q.name, 'Song radio');
    expect(q.items.first.displayTitle, 'Song 0');
  });
}

// A long queue arrives a slice at a time, and the slice knows where it sits.
void slices() {
  Queue sliced({int total = 14022, int from = 13700, int items = 600}) =>
      Queue.fromJson({
        'id': 108, 'name': 'Liked Songs', 'cursor_index': 13958,
        'position_ms': 0, 'rev': 4, 'total': total, 'window_from': from,
        'items': [
          for (var i = 0; i < items; i++)
            {'id': from + i + 1, 'title': 'Song ${from + i}', 'artists': const ['A'],
             'state': 'ready', 'source': 'youtube', 'pos': from + i},
        ],
      });

  test('a queue says how long it really is, not how much of it is here', () {
    final q = sliced();
    expect(q.items, hasLength(600));
    expect(q.total, 14022);
    expect(q.windowFrom, 13700);
    expect(q.windowed, isTrue);
  });

  test('a queue that fits is not a slice of anything', () {
    final q = sliced(total: 12, from: 0, items: 12);
    expect(q.windowed, isFalse);
    expect(q.windowFrom, 0);
  });

  test('an older server, which sends the lot and says nothing about slices', () {
    final q = Queue.fromJson({
      'id': 1, 'name': 'Mine', 'cursor_index': 0, 'position_ms': 0, 'rev': 1,
      'items': [
        {'id': 1, 'title': 'Song', 'artists': const ['A'], 'state': 'ready',
         'source': 'youtube', 'pos': 0},
      ],
    });
    expect(q.total, 1);
    expect(q.windowed, isFalse, reason: 'everything it has is everything there is');
  });
}
