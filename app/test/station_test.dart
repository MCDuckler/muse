// A station is a queue that keeps going, so what matters here is when it is asked for
// more — a queue nearly finished asked twice a second would be a download every time.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/models.dart';

void main() {
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
