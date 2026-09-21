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

  _queueShapes();
  _statusLineTests();
  _searchStateTests();
  _mirrorTests();

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

// Regression: the list endpoint sends `items` as a count, the detail endpoint sends it
// as a list. Assuming one shape crashed every login that already had a queue.
void _queueShapes() {
  test('Queue accepts items as a count and as a list', () {
    final listed = Queue.fromJson(const {
      'id': 1, 'name': 'Now', 'cursor_index': 0, 'position_ms': 0,
      'shuffle': false, 'repeat': 'off', 'rev': 1, 'items': 4,
    });
    expect(listed.itemCount, 4);
    expect(listed.items, isEmpty);

    final detailed = Queue.fromJson(const {
      'id': 1, 'name': 'Now', 'cursor_index': 0, 'position_ms': 0,
      'shuffle': false, 'repeat': 'off', 'rev': 1,
      'items': [
        {'id': 9, 'title': 'x', 'artists': [], 'state': 'ready',
         'source': 'youtube', 'stream_url': '/x'}
      ],
    });
    expect(detailed.itemCount, 1);
    expect(detailed.items.single.id, 9);

    final empty = Queue.fromJson(const {
      'id': 2, 'name': 'Empty', 'cursor_index': 0, 'position_ms': 0,
      'shuffle': false, 'repeat': 'off', 'rev': 1,
    });
    expect(empty.itemCount, 0);
  });
}

// What a row says while a track is being fetched. A spinner alone means "something,
// for some length of time"; these are the words that replace it.
void _statusLineTests() {
  Track make({String state = 'pending', Map<String, dynamic>? progress,
      String? failReason, String? streamUrl}) =>
      Track.fromJson({
        'id': 1, 'title': 'Song', 'artists': const ['A'], 'state': state,
        'source': 'youtube', 'stream_url': streamUrl,
        if (failReason != null) 'fail_reason': failReason,
        if (progress != null) 'progress': progress,
      });

  group('what a downloading row says', () {
    test('shows the stage and a percentage', () {
      final t = make(progress: {
        'stage': 'downloading', 'label': 'Downloading', 'percent': 0.42,
        'speed': '1.2MiB/s',
      });
      expect(t.statusLine, 'Downloading 42% · 1.2MiB/s');
      expect(t.progressFraction, closeTo(0.42, 0.001));
    });

    test('drops the speed when there is none', () {
      final t = make(progress: {
        'stage': 'converting', 'label': 'Converting', 'percent': 0.1, 'speed': null});
      expect(t.statusLine, 'Converting 10%');
    });

    test('a stage without a percentage still reads as progress', () {
      final t = make(progress: {'stage': 'measuring', 'label': 'Checking loudness'});
      expect(t.statusLine, 'Checking loudness…');
      expect(t.progressFraction, isNull, reason: 'and the bar goes indeterminate');
    });

    test('a track with no file behind it says so, and is not "downloading"', () {
      // `pending` means only "no file here yet", which in a mirrored library is true
      // of twenty thousand songs nobody has asked for. Calling all of those
      // downloading put a spinner on every one of them that never went away.
      final t = make();
      expect(t.statusLine, 'Not downloaded yet');
      expect(t.isDownloading, isFalse);
      expect(t.isNotFetched, isTrue);
    });

    test('a track the worker has in hand is downloading', () {
      final t = make(progress: {'stage': 'downloading', 'label': 'Downloading'});
      expect(t.isDownloading, isTrue);
      expect(t.isNotFetched, isFalse);
    });

    test('a failure shows the reason, not a spinner', () {
      final t = make(state: 'failed', failReason: 'Blocked in this region');
      expect(t.statusLine, 'Blocked in this region');
    });

    test('a ready track is back to showing the artist', () {
      final t = make(state: 'ready', streamUrl: '/tracks/1/stream');
      expect(t.statusLine, 'A');
    });
  });
}

// Which of the three search states to show. An empty list after a search used to look
// exactly like a search that had never run.
enum SearchView { prompt, results, nothingFound }

SearchView searchView({
  required bool searched,
  required bool busy,
  required int localCount,
  required int remoteCount,
}) {
  if (searched && !busy && localCount == 0 && remoteCount == 0) {
    return SearchView.nothingFound;
  }
  if (!searched && !busy) return SearchView.prompt;
  return SearchView.results;
}

void _searchStateTests() {
  group('what the search screen shows', () {
    test('before anything is typed, an invitation', () {
      expect(searchView(searched: false, busy: false, localCount: 0, remoteCount: 0),
          SearchView.prompt);
    });

    test('while a query is in flight, the results area', () {
      expect(searchView(searched: false, busy: true, localCount: 0, remoteCount: 0),
          SearchView.results);
    });

    test('after a query that found nothing, it says so', () {
      expect(searchView(searched: true, busy: false, localCount: 0, remoteCount: 0),
          SearchView.nothingFound);
    });

    test('local hits alone are results', () {
      expect(searchView(searched: true, busy: false, localCount: 3, remoteCount: 0),
          SearchView.results);
    });

    test('remote hits alone are results', () {
      expect(searchView(searched: true, busy: false, localCount: 0, remoteCount: 5),
          SearchView.results);
    });

    test('a new query in flight does not flash "nothing found"', () {
      expect(searchView(searched: true, busy: true, localCount: 0, remoteCount: 0),
          SearchView.results);
    });
  });
}

// A mirrored playlist is a view of someone else's list: playable, tagged, and not
// editable, because an edit would either vanish on the next sync or corrupt the mirror.
void _mirrorTests() {
  Playlist make(Map<String, dynamic> j) => Playlist.fromJson({
        'id': 1, 'name': 'Road trip', 'items': 12, ...j,
      });

  group('mirrored playlists', () {
    test('a local playlist is editable and untagged', () {
      final p = make({'kind': 'local'});
      expect(p.isMirror, isFalse);
      expect(p.editable, isTrue);
      expect(p.unmatched, 0);
    });

    test('a spotify playlist is a mirror and not editable', () {
      final p = make({'kind': 'spotify', 'source_name': 'chris', 'unmatched': 3});
      expect(p.isMirror, isTrue);
      expect(p.editable, isFalse);
      expect(p.unmatched, 3, reason: 'the app must be able to say what is missing');
      expect(p.sourceName, 'chris');
    });

    test('the server can override editability explicitly', () {
      expect(make({'kind': 'spotify', 'editable': false}).editable, isFalse);
      expect(make({'kind': 'local', 'editable': false}).editable, isFalse);
    });

    test('an unmatched entry keeps its reason in words', () {
      final u = UnmatchedTrack.fromJson({
        'pos': 4,
        'title': 'Some Song',
        'artists': ['A', 'B'],
        'reason': 'Nothing on YouTube Music matched this song',
      });
      expect(u.pos, 4);
      expect(u.artistLine, 'A, B');
      expect(u.reason, contains('matched'));
    });

    test('an unmatched entry with no artists still reads properly', () {
      final u = UnmatchedTrack.fromJson({'pos': 0, 'title': 'X'});
      expect(u.artistLine, 'Unknown artist');
      expect(u.reason, isNotEmpty);
    });
  });

  test('a listening reply missing its parts still parses', () {
    // A bare `const {}` fallback is a Map<dynamic, dynamic>, and casting it to
    // Map<String, dynamic> threw — so one missing field lost the whole page.
    final l = Listening.fromJson({'songs': []});
    expect(l.plays, 0);
    expect(l.whoName, '');
  });
}
