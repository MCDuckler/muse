import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';

/// The back of one record, and what is drawn on it.
///
/// A board belongs to a song and to a person: yours is yours, and in a jam it is the
/// host's, so one sleeve goes round the room collecting everybody's handwriting rather
/// than everybody getting their own copy. Which of those it is, is the server's
/// decision — this only ever asks for "the board for this track" and is told.
///
/// A ChangeNotifier rather than part of the app's state: a line being drawn moves
/// sixty times a second and the rest of the screen has no business rebuilding for it.
class SleeveBoard extends ChangeNotifier {
  SleeveBoard(this.api);

  final ApiClient api;

  /// Which record is turned over. Nothing is fetched until one is.
  int? _trackId;
  int? get trackId => _trackId;

  final List<SleeveStroke> _strokes = [];
  List<SleeveStroke> get strokes => List.unmodifiable(_strokes);

  bool _loading = false;
  bool get loading => _loading;

  /// The line under the finger, if there is one.
  SleeveStroke? _drawing;
  SleeveStroke? get drawing => _drawing;

  /// The pen. Held here rather than by whatever is drawing with it, so the palette and
  /// the sleeve cannot disagree about which colour is in your hand.
  int ink = 0;
  double nib = 2.4;

  void pickInk(int i) {
    ink = i;
    notifyListeners();
  }

  void pickNib(double w) {
    nib = w;
    notifyListeners();
  }

  /// Whether a record is turned over at all — which is the only time any of this is on
  /// screen.
  bool get open01 => _trackId != null;

  /// How to turn the record back over, set by whatever is drawing it.
  ///
  /// Lives here because the pens live under the record and the record lives on the
  /// stage, and the two do not otherwise know about each other. The board is the one
  /// thing they both hold.
  VoidCallback? onTurnBack;

  // ------------------------------------------------------------- wet paint
  /// How long paint runs for after it is laid down.
  static const Duration drying = Duration(milliseconds: 2600);

  /// When each stroke was first seen here. Strokes that were already on the board when
  /// it was opened are not in this at all: their paint dried long ago, and a board
  /// coming back after a reload should not put on a show of drying again.
  final Map<String, DateTime> _wet = {};
  Timer? _drying;

  /// How fresh a stroke is: one when it has just gone on, zero once it has dried.
  double wetness(String strokeId) {
    final at = _wet[strokeId];
    if (at == null) return 0;
    final since = DateTime.now().difference(at).inMilliseconds;
    return (1 - since / drying.inMilliseconds).clamp(0.0, 1.0);
  }

  void _wetten(String strokeId) {
    _wet[strokeId] = DateTime.now();
    // Paint that is running has to be redrawn while it runs, and nothing else on this
    // screen is moving — so the clock runs only while there is something to see and
    // stops itself the moment the last run has finished.
    _drying ??= Timer.periodic(const Duration(milliseconds: 16), (t) {
      _wet.removeWhere((_, at) => DateTime.now().difference(at) > drying);
      if (_wet.isEmpty) {
        t.cancel();
        _drying = null;
      }
      notifyListeners();
    });
  }

  /// What is sent and how often.
  ///
  /// A line appears on somebody else's screen while it is still being drawn, which is
  /// the whole point of drawing together — but not sixty times a second. Every eighth
  /// of a second is faster than anybody can tell and an order of magnitude less
  /// traffic, and the last send always carries the finished line.
  static const send = Duration(milliseconds: 70);
  Timer? _pending;
  var _sentAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Turn a record over.
  Future<void> open(int trackId) async {
    if (_trackId == trackId) return;
    _trackId = trackId;
    _strokes.clear();
    _drawing = null;
    _loading = true;
    notifyListeners();
    await reload();
  }

  Future<void> reload() async {
    final id = _trackId;
    if (id == null) return;
    try {
      final got = await api.marks(id);
      if (_trackId != id) return;          // turned over again while we were asking
      _strokes
        ..clear()
        ..addAll(got);
    } catch (_) {
      // A board we cannot read is a blank one. Nothing here is worth an error screen.
    }
    _loading = false;
    notifyListeners();
  }

  void close() {
    _flush(force: true);
    _trackId = null;
    _strokes.clear();
    _drawing = null;
    _wet.clear();
    _drying?.cancel();
    _drying = null;
    notifyListeners();
  }

  // ------------------------------------------------------------------ drawing
  /// Start a line. [at] is in the sleeve's own square, 0 to 1.
  void begin(Offset01 at) {
    if (_trackId == null) return;
    _drawing = SleeveStroke(
      id: '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
          '${math.Random().nextInt(1 << 16).toRadixString(36)}',
      ink: ink,
      width: nib,
      points: [at.x, at.y],
    );
    notifyListeners();
  }

  /// Not every wobble: a point closer than this to the last one says nothing the line
  /// does not already say, and a stroke made of a thousand of them is slow to draw and
  /// slower to send.
  ///
  /// A quarter of what it was. At six thousandths of a sleeve the line lagged visibly
  /// behind the finger on anything drawn slowly — the pen only caught up once you had
  /// moved far enough to be worth recording, which is exactly the wrong way round.
  static const double _apart = 0.0015;

  void extend(Offset01 at) {
    final line = _drawing;
    if (line == null) return;
    final n = line.points.length;
    final dx = at.x - line.points[n - 2], dy = at.y - line.points[n - 1];
    if (dx * dx + dy * dy < _apart * _apart) return;
    _drawing = line.copyWith(points: [...line.points, at.x, at.y]);
    notifyListeners();
    _maybeSend();
  }

  void end() {
    final line = _drawing;
    if (line == null) return;
    // A tap with no drag is a dot, and a dot is a mark somebody meant to make.
    final finished = line.points.length == 2
        ? line.copyWith(
            points: [...line.points, line.points[0] + 0.001, line.points[1] + 0.001],
            done: true)
        : line.copyWith(done: true);
    _strokes.add(finished);
    _wetten(finished.id);
    _drawing = null;
    notifyListeners();
    _pending?.cancel();
    _pending = null;
    unawaited(_push(finished));
  }

  /// Take back the last line this device drew.
  Future<void> undo(int? mine) async {
    final id = _trackId;
    if (id == null) return;
    final at = _strokes.lastIndexWhere((s) => s.authorId == null || s.authorId == mine);
    if (at < 0) return;
    final gone = _strokes.removeAt(at);
    notifyListeners();
    try {
      await api.undoMark(id, gone.id);
    } catch (_) {
      _strokes.insert(at.clamp(0, _strokes.length), gone);
      notifyListeners();
    }
  }

  Future<void> wipe() async {
    final id = _trackId;
    if (id == null) return;
    final had = [..._strokes];
    _strokes.clear();
    notifyListeners();
    try {
      await api.wipeMarks(id);
    } catch (_) {
      _strokes.addAll(had);
      notifyListeners();
    }
  }

  void _maybeSend() {
    final since = DateTime.now().difference(_sentAt);
    if (since >= send) {
      _flush();
      return;
    }
    _pending ??= Timer(send - since, _flush);
  }

  void _flush({bool force = false}) {
    _pending?.cancel();
    _pending = null;
    final line = _drawing;
    if (line == null) return;
    _sentAt = DateTime.now();
    unawaited(_push(line));
  }

  Future<void> _push(SleeveStroke stroke) async {
    final id = _trackId;
    if (id == null) return;
    try {
      await api.draw(id, stroke);
    } catch (_) {
      // The next send carries the whole line again, so one that goes missing costs
      // nothing — which is why the line is sent whole rather than as a difference.
    }
  }

  // ------------------------------------------------------- somebody else drawing
  /// A stroke from the room. Replaces the one with the same id, because that is the
  /// same line getting longer.
  void arrived(Map<String, dynamic> data) {
    if (data['track_id'] != _trackId) return;
    final stroke = SleeveStroke.fromJson(data);
    final at = _strokes.indexWhere((s) => s.id == stroke.id);
    if (at >= 0) {
      _strokes[at] = stroke;
    } else {
      _strokes.add(stroke);
    }
    // Somebody else's paint is as wet as your own when it lands.
    if (stroke.done) _wetten(stroke.id);
    notifyListeners();
  }

  void erased(Map<String, dynamic> data) {
    if (data['track_id'] != _trackId) return;
    _strokes.removeWhere((s) => s.id == data['stroke_id']);
    notifyListeners();
  }

  void wiped(Map<String, dynamic> data) {
    if (data['track_id'] != _trackId) return;
    _strokes.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _pending?.cancel();
    _drying?.cancel();
    super.dispose();
  }
}

/// A place on the sleeve, 0 to 1 in both directions.
class Offset01 {
  const Offset01(this.x, this.y);
  final double x;
  final double y;
}
