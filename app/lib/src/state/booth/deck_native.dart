// A deck on the booth's own engine (lib/src/audio/engine.dart): what Deck does in
// place of its libmpv player when the engine is running. See deck.dart, whose
// methods turn here first.
//
// Most of what deck.dart carries for its player is not needed here. The clock is the
// engine's own, read off the sample the sound card is playing (no reports to anchor,
// no suspects, no stalls). A loop is two sample positions in the engine (no wrap
// timer, no learned lateness, no seam reading). A part is another source at another
// level on the same timeline (no load, no gap).
part of 'deck.dart';

/// The engine's hold on one deck.
class _NativeLink {
  _NativeLink(this.engine, this.index);
  final Engine engine;
  final int index;

  /// The record (or its stems) in slot 0; a part made as its own file in slot 1.
  EngineSource? main, part;

  /// What was asked: the engine says so a block later.
  bool want = false;

  /// A seek asked and not yet carried out by the engine: where it was sent.
  Duration? pending;
  int pendingMoves = 0;
  DateTime pendingSince = DateTime.now();

  int ended = 0;
  Timer? watch;
  DeckReading? last;
}

extension _Native on Deck {
  _NativeLink get _n => _native!;

  /// What the engine says now (and the end noticed).
  DeckReading _readNow() {
    final r = _n.engine.read(_n.index);
    _n.last = r;
    final p = _n.pending;
    if (p != null && (r.moves != _n.pendingMoves || DateTime.now().difference(_n.pendingSince) > const Duration(milliseconds: 80))) {
      _n.pending = null;
    }
    return r;
  }

  /// Watched while it plays: the end of the record, and the engine's own word that
  /// it is playing.
  void _nativeWatch() {
    _n.watch?.cancel();
    _n.watch = Timer.periodic(const Duration(milliseconds: 50), (t) {
      if (_disposed) return t.cancel();
      final r = _readNow();
      if (r.ended != _n.ended) {
        _n.ended = r.ended;
        _n.want = false;
        if (!_ended_) _ended();
      }
      if (!_n.want && !r.playing) t.cancel();
    });
  }

  bool get _nativePlaying => _n.want && !_ended_;

  Duration _nativePositionAt(DateTime now) {
    final p = _n.pending;
    if (p != null) {
      _readNow();
      final still = _n.pending;
      if (still != null) return still;
    }
    final at = _n.engine.position(_n.index);
    final r = _n.last ?? _readNow();
    final ahead = now.difference(DateTime.now()).inMicroseconds / 1e6;
    final s = at + (r.playing ? ahead * r.rate : 0);
    final out = Duration(microseconds: (s * 1e6).round());
    final end = duration;
    return end != null && end > Duration.zero && out > end ? end : (out < Duration.zero ? Duration.zero : out);
  }

  /// The record's beats, as the engine counts them: the steady grid drawn across the
  /// whole record where there is one, the analysis's own beats otherwise; and which
  /// of them starts a bar.
  void _nativeBeats() {
    final t = timing;
    final e = _n.engine;
    if (t == null || !t.hasBeats) {
      e.beats(_n.index, const []);
      return;
    }
    final s = t.steady;
    if (s != null) {
      final lengthMs = (duration ?? track?.duration ?? Duration(milliseconds: t.beats.last + 60000)).inMilliseconds + 8 * s.period;
      final k0 = (-s.origin / s.period).floor();
      final k1 = ((lengthMs - s.origin) / s.period).ceil();
      e.beats(_n.index, [for (var k = k0; k <= k1; k++) (s.origin + k * s.period) / 1000]);
      e.barOne(_n.index, ((t.barStartsOn - k0) % 4 + 4) % 4);
    } else {
      // Not steady: each beat where the grid fitted round it puts it (what the old
      // engine's hold read too, TrackTiming.smoothBeatAt), not where the tracker left
      // it — a tracker's beat is a few milliseconds off either way, and the engine
      // holds a record to exactly what it is told.
      final out = <double>[];
      for (var k = 0; k < t.beats.length; k++) {
        final at = t.beatTime(k, near: Duration(milliseconds: t.beats[k]));
        out.add((at ?? Duration(milliseconds: t.beats[k])).inMicroseconds / 1e6);
      }
      for (var k = 1; k < out.length; k++) {
        if (out[k] <= out[k - 1]) out[k] = out[k - 1] + 0.001;
      }
      e.beats(_n.index, out);
      e.barOne(_n.index, t.barStartsOn);
    }
  }

  /// The record (or its stems, or a part) into the engine and onto the deck, parked
  /// at [start].
  Future<void> _nativeLoad(Track track, Duration start) async {
    final e = _n.engine;
    final i = _n.index;
    _n.want = false;
    e.play(i, false);
    e.loop(i, null, null);
    // What it was playing goes once this is in.
    final oldMain = _n.main, oldPart = _n.part;
    _n.part = null;
    final stems = _stemsFrom;
    final String input;
    final String key;
    if (stems != null) {
      input = stems;
      key = '${track.id}/stems';
    } else if (part != null) {
      final mine = parts?.pathFor(track.id, part!);
      input = mine ?? api.stemUrl(track, part!);
      key = '${track.id}/$part';
    } else {
      input = offlinePath?.call(track.id) ?? api.streamUrl(track);
      key = '${track.id}';
    }
    final src = e.decode(key, input, headers: input.startsWith('http') ? api.streamHeaders : null, channels: stems != null ? 6 : 2);
    _n.main = src;
    stemmed = stems != null;
    stemLevels = stemmed ? StemLevels.of(part) : StemLevels.all;
    e.source(i, 0, src.id);
    e.source(i, 1, 0);
    _nativeGains(Duration.zero);
    e.seek(i, start);
    _nativeBeats();
    e.setRate(i, tempo);
    e.bend(i, 1);
    e.keylock(i, keylock);
    // Parked: enough of it decoded to play from where it waits.
    await src.ready(start.inMicroseconds / 1e6);
    if (src.failed) {
      trouble = src.trouble;
      PlaybackLog.booth('deck $name: ${src.trouble}');
    }
    oldMain?.release();
    oldPart?.release();
    _n.pending = start;
    _n.pendingSince = DateTime.now();
    _n.pendingMoves = _readNow().moves;
  }

  /// The levels of the sources: the record (or stems, at [stemLevels]) and a part.
  void _nativeGains(Duration ramp) {
    final e = _n.engine;
    final i = _n.index;
    final onPart = _n.part != null;
    final l = stemmed ? stemLevels : StemLevels.all;
    e.sourceGain(i, 0, onPart ? 0 : 1, drums: l.drums, rest: l.rest, vocals: l.vocals, ramp: ramp);
    e.sourceGain(i, 1, onPart ? 1 : 0, ramp: ramp);
  }

  /// A part made as its own file, crossfaded in over the record on the same timeline:
  /// no load, no gap, no place lost.
  Future<bool> _nativeSwap(Track t, String? part) async {
    final e = _n.engine;
    final i = _n.index;
    this.part = part;
    final old = _n.part;
    if (part == null) {
      _n.part = null;
      _nativeGains(const Duration(milliseconds: 60));
      old?.release();
      notifyListeners();
      return true;
    }
    final mine = parts?.pathFor(t.id, part);
    final input = mine ?? api.stemUrl(t, part);
    final src = e.decode('${t.id}/$part', input, headers: input.startsWith('http') ? api.streamHeaders : null);
    await src.ready(position.inMicroseconds / 1e6, ahead: 6);
    if (track?.id != t.id || this.part != part) {
      src.release();
      return false;
    }
    if (src.failed) {
      src.release();
      trouble = src.trouble;
      notifyListeners();
      return false;
    }
    e.source(i, 1, src.id);
    _n.part = src;
    _nativeGains(const Duration(milliseconds: 60));
    old?.release();
    notifyListeners();
    return true;
  }

  Future<void> _nativePlay() async {
    final d = duration;
    if (_ended_ && (d == null || position >= d - const Duration(seconds: 1))) {
      await seek(cuePoint ?? Duration.zero);
    }
    _ended_ = false;
    _freshlyLoaded = false;
    _n.want = true;
    _n.engine.play(_n.index, true);
    _nativeWatch();
    notifyListeners();
  }

  /// Started in step with [master] — by the engine, to the sample: now, or as the
  /// master is heard at [at].
  void _nativeStartWith(Deck master, {int every = 1, Duration? at, Duration offset = Duration.zero}) {
    _ended_ = false;
    _freshlyLoaded = false;
    _n.want = true;
    _n.engine.start(_n.index, master._native?.index, every: every, at: at, offset: offset);
    _nativeWatch();
    notifyListeners();
  }

  Future<void> _nativePause() async {
    _n.want = false;
    _n.engine.play(_n.index, false);
    notifyListeners();
  }

  Future<void> _nativeSeek(Duration to) async {
    final at = to < Duration.zero ? Duration.zero : to;
    placed++;
    _n.pendingMoves = _readNow().moves;
    _n.pending = at;
    _n.pendingSince = DateTime.now();
    _n.engine.seek(_n.index, at);
    notifyListeners();
  }

  void _nativeRate() {
    // The pitch is the engine's rate; anything the booth bends it by on top (the jog,
    // a nudge) is the engine's bend, so a synced deck keeps the place it is left in.
    _n.engine.setRate(_n.index, pitch);
    _n.engine.bend(_n.index, pitch <= 0 ? 1 : tempo / pitch);
  }

  void _nativeLoop() {
    final a = loopStart, b = loopEnd;
    _n.engine.loop(_n.index, a != null && b != null && b > a ? a : null, a != null && b != null && b > a ? b : null);
  }

  Future<void> _nativeBrake(Duration length) async {
    braking = true;
    notifyListeners();
    _n.engine.brake(_n.index, length);
    await Future<void>.delayed(length + const Duration(milliseconds: 30));
    _n.want = false;
    braking = false;
    notifyListeners();
  }

  void _nativeDispose() {
    _n.watch?.cancel();
    _n.engine.play(_n.index, false);
    _n.engine.source(_n.index, 0, 0);
    _n.engine.source(_n.index, 1, 0);
    _n.main?.release();
    _n.part?.release();
  }
}
