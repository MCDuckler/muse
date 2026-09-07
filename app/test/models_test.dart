import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/models.dart';

void main() {
  group('Track', () {
    test('a pending track is not playable and says so', () {
      final t = Track.fromJson(const {
        'id': 1, 'title': 'Queued Song', 'artists': ['Someone'],
        'state': 'pending', 'source': 'youtube', 'stream_url': null,
      });
      expect(t.isReady, isFalse);
      expect(t.isPending, isTrue);
      expect(t.artistLine, 'Someone');
    });

    test('a ready track carries a stream path', () {
      final t = Track.fromJson(const {
        'id': 2, 'title': 'Done', 'artists': ['A', 'B'], 'state': 'ready',
        'source': 'youtube', 'stream_url': '/tracks/2/stream', 'duration_ms': 1000,
      });
      expect(t.isReady, isTrue);
      expect(t.artistLine, 'A, B');
      expect(t.duration, const Duration(seconds: 1));
    });

    test('missing artists never render as an empty line', () {
      final t = Track.fromJson(const {
        'id': 3, 'title': 'Nameless', 'state': 'ready', 'source': 'custom',
        'stream_url': '/tracks/3/stream',
      });
      expect(t.artistLine, 'Unknown artist');
    });

    test('queue items keep their origin so radio is distinguishable', () {
      final t = Track.fromJson(const {
        'id': 4, 'title': 'Auto', 'artists': [], 'state': 'ready',
        'source': 'youtube', 'stream_url': '/x', 'origin': 'radio',
      });
      expect(t.origin, 'radio');
    });
  });

  group('Queue', () {
    test('parses items and cursor', () {
      final q = Queue.fromJson(const {
        'id': 7, 'name': 'Now', 'cursor_index': 1, 'position_ms': 4200,
        'shuffle': false, 'repeat': 'off', 'rev': 3,
        'items': [
          {'id': 1, 'title': 'One', 'artists': [], 'state': 'ready',
           'source': 'youtube', 'stream_url': '/a', 'origin': 'user'},
          {'id': 2, 'title': 'Two', 'artists': [], 'state': 'ready',
           'source': 'youtube', 'stream_url': '/b', 'origin': 'radio'},
        ],
      });
      expect(q.itemCount, 2);
      expect(q.cursorIndex, 1);
      expect(q.rev, 3);
      expect(q.items[1].origin, 'radio');
    });
  });

  group('Playlist', () {
    test('accepts both the list form and the count form of items', () {
      final listed = Playlist.fromJson(const {
        'id': 1, 'name': 'Trip', 'kind': 'local',
        'items': [
          {'id': 9, 'title': 'x', 'artists': [], 'state': 'ready',
           'source': 'youtube', 'stream_url': '/x'}
        ],
      });
      final counted = Playlist.fromJson(const {
        'id': 2, 'name': 'Synced', 'kind': 'spotify', 'items': 42,
      });
      expect(listed.itemCount, 1);
      expect(listed.items.single.id, 9);
      expect(counted.itemCount, 42);
      expect(counted.items, isEmpty);
    });
  });
}
