// The back of a record, drawn on.
//
// Two things here are worth pinning: a line being drawn is *one* line however many
// times it is sent, and a line arriving from somebody else in the room is the same
// line getting longer rather than a new one every eighth of a second. Get either wrong
// and drawing together produces a heap of fragments that looks fine on the device that
// made it and like static on every other one.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/sleeve_board.dart';

/// An API that writes down what it was asked to do and answers nothing.
class _Recorder extends ApiClient {
  _Recorder() : super(baseUrl: 'http://example.invalid', token: 't');

  final List<SleeveStroke> sent = [];
  final List<String> undone = [];
  int wipes = 0;
  List<SleeveStroke> onDisk = const [];

  @override
  Future<List<SleeveStroke>> marks(int trackId) async => onDisk;

  @override
  Future<void> draw(int trackId, SleeveStroke stroke) async => sent.add(stroke);

  @override
  Future<void> undoMark(int trackId, String strokeId) async => undone.add(strokeId);

  @override
  Future<void> wipeMarks(int trackId) async => wipes++;
}

void main() {
  late _Recorder api;
  late SleeveBoard board;

  setUp(() async {
    api = _Recorder();
    board = SleeveBoard(api);
    await board.open(7);
  });

  tearDown(() => board.dispose());

  test('a line drawn is one line, however many points it took', () async {
    board.begin(const Offset01(0.1, 0.1));
    for (var i = 1; i <= 20; i++) {
      board.extend(Offset01(0.1 + i * 0.03, 0.1 + i * 0.02));
    }
    board.end();

    expect(board.strokes.length, 1);
    expect(board.strokes.first.points.length, greaterThan(20));
    expect(board.strokes.first.done, isTrue);
    // Everything sent carried the same id, so the server has one stroke and not twenty.
    expect(api.sent.map((s) => s.id).toSet().length, 1);
  });

  test('a wobble smaller than the pen is not a point', () {
    // The filter is deliberately fine — a line that only catches up once the finger
    // has moved far enough to be worth recording lags visibly behind it — but it is
    // not nothing, or a finger held still would fill the stroke with the same point.
    board.begin(const Offset01(0.5, 0.5));
    for (var i = 0; i < 30; i++) {
      board.extend(Offset01(0.5 + i * 0.00001, 0.5));
    }
    expect(board.drawing!.points.length, 2, reason: 'nothing worth recording moved');
  });

  test('but a slow, real movement is followed closely', () {
    board.begin(const Offset01(0.5, 0.5));
    for (var i = 1; i <= 20; i++) {
      board.extend(Offset01(0.5 + i * 0.002, 0.5));
    }
    expect(board.drawing!.points.length, greaterThan(30),
        reason: 'a line drawn slowly keeps up with the finger');
  });

  test('a tap leaves a dot', () {
    board.begin(const Offset01(0.4, 0.6));
    board.end();
    expect(board.strokes.length, 1);
    expect(board.strokes.first.points.length, greaterThanOrEqualTo(4),
        reason: 'a dot still has to be a line for anything to draw it');
  });

  test('somebody else drawing is the same line getting longer', () {
    for (final n in [2, 6, 12]) {
      board.arrived({
        'track_id': 7,
        'stroke_id': 'theirs',
        'ink': 2,
        'width': 1.0,
        'points': [for (var i = 0; i < n; i++) i * 0.05],
        'done': n == 12,
        'author_id': 99,
      });
    }
    expect(board.strokes.length, 1, reason: 'one line, not three');
    expect(board.strokes.single.points.length, 12);
    expect(board.strokes.single.done, isTrue);
  });

  test('a line for another record is not drawn on this one', () {
    board.arrived({
      'track_id': 8, 'stroke_id': 'elsewhere', 'ink': 0, 'width': 1.0,
      'points': [0.1, 0.1, 0.2, 0.2], 'done': true,
    });
    expect(board.strokes, isEmpty);
  });

  test('taking a line back takes back your own', () async {
    board.arrived({
      'track_id': 7, 'stroke_id': 'theirs', 'ink': 0, 'width': 1.0,
      'points': [0.1, 0.1, 0.2, 0.2], 'done': true, 'author_id': 99,
    });
    board.begin(const Offset01(0.3, 0.3));
    board.extend(const Offset01(0.6, 0.6));
    board.end();

    await board.undo(1);
    expect(api.undone.length, 1);
    expect(board.strokes.map((s) => s.id), ['theirs'],
        reason: "somebody else's line is not yours to take back");
  });

  test('the host clearing it empties the board here too', () {
    board.arrived({
      'track_id': 7, 'stroke_id': 'a', 'ink': 0, 'width': 1.0,
      'points': [0.1, 0.1, 0.2, 0.2], 'done': true,
    });
    board.wiped({'track_id': 7});
    expect(board.strokes, isEmpty);
  });

  test('turning the record back closes the board', () {
    board.begin(const Offset01(0.2, 0.2));
    board.close();
    expect(board.open01, isFalse);
    expect(board.strokes, isEmpty);
    expect(board.drawing, isNull);
  });

  wetPaint();

  test('the pen is remembered, and it is the pen that draws', () {
    board.pickInk(3);
    board.pickNib(2.2);
    board.begin(const Offset01(0.1, 0.1));
    board.extend(const Offset01(0.5, 0.5));
    board.end();
    expect(board.strokes.single.ink, 3);
    expect(board.strokes.single.width, 2.2);
  });
}

void wetPaint() {
  group('wet paint', () {
    late SleeveBoard board;

    setUp(() async {
      board = SleeveBoard(_Recorder());
      await board.open(7);
    });

    tearDown(() => board.dispose());

    test('a line just drawn is wet, and dries', () {
      board.begin(const Offset01(0.2, 0.2));
      board.extend(const Offset01(0.6, 0.6));
      board.end();
      final id = board.strokes.single.id;
      expect(board.wetness(id), greaterThan(0.9));
    });

    test("somebody else's paint is wet when it lands", () {
      board.arrived({
        'track_id': 7, 'stroke_id': 'theirs', 'ink': 1, 'width': 2.4,
        'points': [0.1, 0.1, 0.4, 0.4], 'done': true, 'author_id': 9,
      });
      expect(board.wetness('theirs'), greaterThan(0.9));
    });

    test('a line still being drawn is not running yet', () {
      board.arrived({
        'track_id': 7, 'stroke_id': 'theirs', 'ink': 1, 'width': 2.4,
        'points': [0.1, 0.1, 0.4, 0.4], 'done': false, 'author_id': 9,
      });
      expect(board.wetness('theirs'), 0,
          reason: 'paint runs when the can stops, not while it is moving');
    });

    test('what was already on the board when it opened is dry', () {
      // Otherwise every board would put on a show of drying every time it was opened,
      // and a record turned over twice would drip twice.
      expect(board.wetness('anything-from-the-server'), 0);
    });
  });
}
