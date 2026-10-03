// The board: banks of pads beside the decks, pressed from the screen, the keys, a
// controller, or a phone — and what a press does.
//
// One per booth (Booth.board). It owns the document (what the pads are), the sampler
// (what plays them), which bank is on show, and the one piece of timing that is the
// booth's business and not the sampler's: a pad that waits for the master's beat.
// It is its own ChangeNotifier, not the booth's — a sweep across a pad thirty times
// a second is no reason to rebuild the room.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../api/client.dart';
import '../booth.dart';
import '../deck.dart';
import 'board_face.dart';
import 'sample_fetch_none.dart' if (dart.library.io) 'sample_fetch_io.dart' as files;
import 'board_keys.dart';
import 'board_store.dart';
import 'pad_spec.dart';
import 'sampler.dart';
import 'samples.dart';

/// What a pad is doing, for whoever draws it.
class PadState {
  const PadState({required this.sounding, this.firedAt, this.length, this.waitingUntil, this.held = false});
  final bool sounding;
  final DateTime? firedAt;
  final Duration? length;

  /// Pressed, and waiting for the beat: when it will go.
  final DateTime? waitingUntil;
  final bool held;

  bool get waiting => waitingUntil != null;

  /// 0..1 through the sound, by [now].
  double? progressAt(DateTime now) {
    final at = firedAt, l = length;
    if (!sounding || at == null || l == null || l <= Duration.zero) return null;
    final t = now.difference(at).inMicroseconds / l.inMicroseconds;
    return t.clamp(0.0, 1.0);
  }

  static const quiet = PadState(sounding: false);
}

class Soundboard extends ChangeNotifier implements BoardFace {
  Soundboard(this.booth, {Sampler? sampler, BoardStore? store})
      : sampler = sampler ?? Sampler(playerVolume: booth.mixer.playerVolume),
        store = store ?? BoardStore.forThisDevice() {
    this.sampler.changed.addListener(_voicesChanged);
    booth.moves.addListener(_masterMoved);
  }

  final Booth booth;
  final Sampler sampler;
  final BoardStore store;

  @override
  BoardDoc doc = starter();

  /// Which bank is on show, 0..3.
  @override
  int bank = 0;

  @override
  bool get editable => true;

  @override
  Float32List? peaksOf(int sampleId) => sampler.library.peaks[sampleId];

  bool _loaded = false;
  bool get loaded => _loaded;
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  /// Pads pressed and waiting for the beat, by key.
  final _waiting = <String, ({Timer timer, DateTime at})>{};

  double _masterSeen = 1.0;
  Timer? _save;

  /// The level the booth's decks are held at while something ducks them.
  double _ducked = 1.0;

  // ------------------------------------------------------------------ the document
  /// A first board: the kit's sounds across the first row of A.
  static BoardDoc starter() {
    final doc = BoardDoc.empty();
    final a = doc.banks[0].pads;
    a[0] = const PadSpec(sampleId: SampleKit.impact, name: 'IMPACT', colour: PadColour.a, choke: 1);
    a[1] = const PadSpec(
        sampleId: SampleKit.riser, name: 'RISER', colour: PadColour.violet, mode: PadMode.toggle, quantise: Quantise.bar);
    a[2] = const PadSpec(sampleId: SampleKit.sweepUp, name: 'SWEEP UP', colour: PadColour.teal);
    a[3] = const PadSpec(sampleId: SampleKit.sweepDown, name: 'SWEEP DOWN', colour: PadColour.teal);
    a[4] = const PadSpec(sampleId: SampleKit.hydrant, name: 'HYDRANT', colour: PadColour.orange, mode: PadMode.hold);
    return doc;
  }

  /// The board as it was kept, and the shown bank made ready.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final kept = await store.load();
    if (kept != null) doc = kept;
    _masterSeen = booth.master_;
    await refreshLibrary();
    await warm();
    notifyListeners();
  }

  void _keepSoon() {
    _save?.cancel();
    _save = Timer(const Duration(seconds: 1), () => unawaited(_keep()));
  }

  Future<void> _keep() async {
    final theirs = await store.save(doc);
    if (theirs == null || _disposed) return;
    // Another screen saved first: theirs is the board now.
    doc = theirs;
    notifyListeners();
    await warm();
  }

  // ------------------------------------------------------------------ the user's own sounds
  ApiClient get _api => booth.api;

  /// Whether this library can hold the user's own sounds (a server to keep them).
  bool get hasServer => _api.token != null;

  /// The user's own samples and the house's shelf, as the server lists them now.
  Future<void> refreshLibrary() async {
    if (!hasServer) return;
    try {
      final shelves = await _api.sampleShelves();
      sampler.library
        ..takeServerList(shelves.own)
        ..takeHouseList(shelves.house);
      notifyListeners();
    } catch (e) {
      debugPrint('board: the library did not come — $e');
    }
  }

  /// A file of the user's, kept on the server and in the library: the sample.
  Future<Sample> importBytes(String filename, List<int> bytes, {String? name}) async {
    final j = await _api.uploadSample(bytes, filename, name: name);
    sampler.library.takeServerList([j, ...await _api.samples()].fold(<int, Map<String, dynamic>>{}, (m, s) {
      m[(s['id'] as num).toInt()] = s;
      return m;
    }).values.toList());
    notifyListeners();
    return sampler.library.byId((j['id'] as num).toInt())!;
  }

  /// [bars] of the record on [deck], from the start of the bar it is in, cut on the
  /// server: the sample. Without beats, from where the record is.
  Future<Sample> cutFromDeck(Deck deck, int bars) async {
    final t = deck.track;
    if (t == null) throw StateError('nothing on ${deck.name}');
    final at = deck.position;
    final beat = deck.beat ?? const Duration(milliseconds: 500);
    final bar = beat * 4;
    var from = at;
    final next = deck.nextBeat(at, every: 4);
    if (next != null) {
      final before = next - bar;
      from = before >= Duration.zero ? before : next;
    }
    final to = from + bar * bars;
    final j = await _api.cutSample(
      trackId: t.id,
      fromMs: from.inMilliseconds,
      toMs: to.inMilliseconds,
      name: '${t.displayTitle} · $bars bar${bars == 1 ? '' : 's'}',
    );
    await refreshLibrary();
    booth.note(BoothEventKind.cue, 'board: cut $bars bar${bars == 1 ? '' : 's'} of ${t.displayTitle}');
    return sampler.library.byId((j['id'] as num).toInt())!;
  }

  Future<void> renameSample(Sample s, String name) async {
    await _api.renameSample(s.id, name);
    await refreshLibrary();
  }

  /// A sample gone from the library, the server and every pad that held it.
  Future<void> forgetSample(Sample s) async {
    for (final p in doc.allPads.toList()) {
      if (p.spec.sampleId == s.id) await setPad(p.bank, p.pad, null);
    }
    await _api.deleteSample(s.id);
    await files.forgetSampleFile(s.id);
    await refreshLibrary();
  }

  /// The pad's name on the sampler: 'A:3'.
  static String keyOf(int bank, int pad) => '${BoardDoc.bankNames[bank]}:${pad + 1}';

  /// Back from a key: (bank, pad).
  static (int, int)? placeOf(String key) {
    final i = key.indexOf(':');
    if (i < 0) return null;
    final b = BoardDoc.bankNames.indexOf(key.substring(0, i));
    final p = int.tryParse(key.substring(i + 1));
    if (b < 0 || p == null) return null;
    return (b, p - 1);
  }

  @override
  PadSpec? pad(int bank, int pad) => doc.pad(bank, pad);

  /// What the pad at [bank], [pad] is doing.
  @override
  PadState stateOf(int bank, int pad) {
    final key = keyOf(bank, pad);
    final w = _waiting[key];
    if (w != null) return PadState(sounding: false, waitingUntil: w.at);
    final v = sampler.voices[key];
    if (v == null || !v.sounding) return PadState.quiet;
    return PadState(sounding: true, firedAt: v.firedAt, length: v.length, held: v.held);
  }

  /// Whether anything is sounding at all, and the colour of the loudest claim on
  /// the bar's light: the pad fired last.
  @override
  bool get anySounding => sampler.sounding.isNotEmpty;

  @override
  PadSpec? get lastFired {
    Voice? last;
    for (final v in sampler.sounding) {
      if (last == null || v.pressedAt.isAfter(last.pressedAt)) last = v;
    }
    return last?.spec;
  }

  // ------------------------------------------------------------------ warming
  /// The pads whose sounds are kept ready: the shown bank's and the pinned row's.
  Set<String> get _warmSet {
    final keep = <String>{_auditionKey};
    for (var p = 0; p < Bank.size; p++) {
      if (doc.pad(bank, p) != null) keep.add(keyOf(bank, p));
    }
    final s = doc.strip;
    if (s != null) {
      for (var i = 0; i < Bank.across; i++) {
        final p = s.row * Bank.across + i;
        if (doc.pad(s.bank, p) != null) keep.add(keyOf(s.bank, p));
      }
    }
    return keep;
  }

  /// Every pad in the warm set readied, the rest let go.
  Future<void> warm() async {
    final keep = _warmSet;
    await sampler.cool(keep);
    for (final key in keep) {
      await _warmOne(key);
    }
  }

  Future<Voice?> _warmOne(String key) async {
    final place = placeOf(key);
    if (place == null) return null;
    final spec = doc.pad(place.$1, place.$2);
    if (spec == null) return null;
    final sample = sampler.library.byId(spec.sampleId);
    if (sample == null) return null;
    return sampler.warm(key, sample, spec, level: _levelFor(spec));
  }

  double _levelFor(PadSpec spec) => (spec.gain * doc.level * booth.master_).clamp(0.0, 1.0);

  Future<void> _relevel() async {
    for (final v in sampler.voices.values.toList()) {
      await sampler.setLevel(v.key, _levelFor(v.spec));
    }
  }

  /// The master fader moved (a controller's): every voice follows it.
  void _masterMoved() {
    if (booth.master_ == _masterSeen) return;
    _masterSeen = booth.master_;
    unawaited(_relevel());
  }

  // ------------------------------------------------------------------ playing
  @override
  Future<void> showBank(int i) async {
    final to = i.clamp(0, doc.banks.length - 1);
    if (to == bank) return;
    bank = to;
    notifyListeners();
    await warm();
  }

  Future<void> stepBank(int by) => showBank((bank + by) % doc.banks.length);

  /// A pad pressed. What happens is the pad's mode: a one-shot fires, a hold fires
  /// until [release], a toggle or a loop fires or stops. With quantise on and the
  /// master playing, the firing waits for its beat; pressed again while waiting, it
  /// is called off.
  @override
  Future<void> press(int bank, int pad) async {
    final spec = doc.pad(bank, pad);
    if (spec == null) return;
    final key = keyOf(bank, pad);
    final waiting = _waiting.remove(key);
    if (waiting != null) {
      waiting.timer.cancel();
      notifyListeners();
      return;
    }
    final v = sampler.voices[key];
    if ((spec.mode == PadMode.toggle || spec.mode == PadMode.loop) && v != null && v.sounding) {
      await sampler.stop(key: key, fade: const Duration(milliseconds: 20));
      return;
    }
    final wait = _untilTheBeat(spec);
    if (wait == null) {
      await _fire(key, spec);
      return;
    }
    final at = DateTime.now().add(wait);
    _waiting[key] = (
      at: at,
      timer: Timer(wait, () {
        _waiting.remove(key);
        unawaited(_fire(key, spec));
      }),
    );
    notifyListeners();
  }

  /// How long a quantised pad waits: to the master's next beat or bar, less the
  /// lead the booth has learned its engine needs to start on time. Null to go now.
  Duration? _untilTheBeat(PadSpec spec) {
    if (spec.quantise == Quantise.off) return null;
    final m = booth.master;
    if (!m.playing) return null;
    final now = DateTime.now();
    var wait = m.untilNextBeat(now, every: spec.quantise.every);
    if (wait == null) return null;
    final lead = booth.learned.startLead;
    wait -= Duration(microseconds: lead.inMicroseconds.clamp(0, 80000));
    // Too close to make: the one after.
    if (wait < const Duration(milliseconds: 15)) {
      final beat = m.beat;
      if (beat == null) return null;
      wait += Duration(microseconds: (beat.inMicroseconds * spec.quantise.every / m.tempo).round());
    }
    return wait;
  }

  Future<void> _fire(String key, PadSpec spec) async {
    var v = sampler.voices[key];
    if (v == null || v.sample.id != spec.sampleId) v = await _warmOne(key);
    if (v == null) return;
    await sampler.choke(spec.choke, except: key);
    await sampler.fire(key);
    booth.note(BoothEventKind.cue, 'board: ${spec.name}');
    _duck();
  }

  /// [spec] heard on its own, from its trim-in, with no choke, no duck and no
  /// waiting: the edit panel's listen button. Stopped by [stopAll], or by the pad.
  Future<void> listen(int bank, int pad) async {
    final spec = doc.pad(bank, pad);
    if (spec == null) return;
    final key = keyOf(bank, pad);
    final v = sampler.voices[key] ?? await _warmOne(key);
    if (v == null) return;
    await sampler.fire(key);
  }

  /// A sample from the library heard before it is on any pad: one voice of its own,
  /// re-used for the next audition. Stopped by [stopAll] or the next one.
  static const _auditionKey = '~';

  Future<void> audition(Sample sample) async {
    final spec = PadSpec(sampleId: sample.id, name: sample.name);
    final v = await sampler.warm(_auditionKey, sample, spec, level: (doc.level * booth.master_).clamp(0.0, 1.0));
    if (v == null) return;
    await sampler.fire(_auditionKey);
  }

  bool get auditioning => sampler.voices[_auditionKey]?.sounding ?? false;

  /// A hold pad let go; nothing for any other kind.
  @override
  Future<void> release(int bank, int pad) async {
    final spec = doc.pad(bank, pad);
    if (spec == null || spec.mode != PadMode.hold) return;
    final key = keyOf(bank, pad);
    final waiting = _waiting.remove(key);
    if (waiting != null) {
      // Let go before its beat came: it never goes.
      waiting.timer.cancel();
      notifyListeners();
      return;
    }
    await sampler.release(key);
  }

  @override
  Future<void> stopAll() async {
    for (final w in _waiting.values) {
      w.timer.cancel();
    }
    _waiting.clear();
    await sampler.stop(fade: const Duration(milliseconds: 20));
    notifyListeners();
  }

  void _voicesChanged() {
    _duck();
    notifyListeners();
  }

  /// The decks dip by the deepest duck among the sounding pads: quickly down, and
  /// back up over a quarter of a second once the last of them is quiet.
  void _duck() {
    var deepest = 0.0;
    for (final v in sampler.sounding) {
      if (v.spec.duck > deepest) deepest = v.spec.duck;
    }
    final want = 1 - 0.5 * deepest;
    if (want == _ducked) return;
    final down = want < _ducked;
    _ducked = want;
    unawaited(booth.setDuck(want, over: Duration(milliseconds: down ? 20 : 250)));
  }

  // ------------------------------------------------------------------ editing
  @override
  Future<void> setLevel(double v) async {
    doc.level = v.clamp(0.0, 1.0);
    notifyListeners();
    await _relevel();
    _keepSoon();
  }

  /// The pad at [bank], [pad] made [spec] — or cleared with null.
  Future<void> setPad(int bank, int pad, PadSpec? spec) async {
    if (bank < 0 || bank >= doc.banks.length || pad < 0 || pad >= Bank.size) return;
    final key = keyOf(bank, pad);
    if (spec == null) {
      await sampler.stop(key: key);
      await sampler.cool(_warmSet..remove(key));
    }
    doc.banks[bank].pads[pad] = spec;
    doc.rev++;
    notifyListeners();
    if (spec != null && _warmSet.contains(key)) await _warmOne(key);
    _keepSoon();
  }

  /// Two pads swapped, across banks or not.
  Future<void> swap((int, int) from, (int, int) to) async {
    final a = doc.pad(from.$1, from.$2), b = doc.pad(to.$1, to.$2);
    if (a == null && b == null) return;
    await sampler.stop(key: keyOf(from.$1, from.$2));
    await sampler.stop(key: keyOf(to.$1, to.$2));
    doc.banks[from.$1].pads[from.$2] = b;
    doc.banks[to.$1].pads[to.$2] = a;
    doc.rev++;
    notifyListeners();
    await warm();
    _keepSoon();
  }

  Future<void> renameBank(int i, String name) async {
    doc.banks[i].name = name.trim().isEmpty ? BoardDoc.bankNames[i] : name.trim();
    doc.rev++;
    notifyListeners();
    _keepSoon();
  }

  /// The shown bank's first row pinned under the decks, or — pinned already — let go.
  Future<void> toggleStrip() => setStrip(doc.strip == null ? StripSpec(bank: bank, row: 0) : null);

  Future<void> setStrip(StripSpec? strip) async {
    doc.strip = strip;
    notifyListeners();
    await warm();
    _keepSoon();
  }

  // ------------------------------------------------------------------ the keys
  /// A key of the desk's, down or up. True when it was the board's.
  bool keyEvent(KeyEvent e, {required bool typing, required bool shift}) {
    if (e is KeyRepeatEvent) return BoardKeys.isPadKey(e.logicalKey) || BoardKeys.isStop(e.logicalKey);
    final k = e.logicalKey;
    final pad = BoardKeys.padFor(k, shift: shift);
    if (pad != null) {
      if (e is KeyDownEvent) {
        unawaited(press(bank, pad));
      } else if (e is KeyUpEvent) {
        unawaited(release(bank, pad));
        // Shift let go before the key: the pad it would be without shift lets go too.
        if (shift) unawaited(release(bank, pad - 8 < 0 ? pad + 8 : pad - 8));
      }
      return true;
    }
    if (BoardKeys.isStop(k)) {
      if (e is KeyDownEvent) unawaited(stopAll());
      return true;
    }
    if (typing || e is! KeyDownEvent) return false;
    final step = BoardKeys.bankStep(k);
    if (step != 0) {
      unawaited(stepBank(step));
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    _disposed = true;
    _save?.cancel();
    for (final w in _waiting.values) {
      w.timer.cancel();
    }
    sampler.changed.removeListener(_voicesChanged);
    booth.moves.removeListener(_masterMoved);
    unawaited(sampler.dispose());
    super.dispose();
  }
}
