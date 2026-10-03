/// Where hardware intent becomes booth calls — one binding for every controller.
///
/// The binding knows nothing about bytes: it takes [SurfaceEvent]s by their names
/// (see Controls) and drives the Booth, and it watches the Booth to say which lights
/// should be on. The modifiers live here too: STOP held is shift, SCRATCH flips the
/// jog wheel between nudging and dragging, the pitch fader's range cycles on
/// shift + pitch reset.
///
/// What the layout calls `gain` — the knob above the fader on a Hercules — is the
/// FILTER here: the booth has no trim (loudness is matched from the server's
/// measurement), and a filter knob is the one every DJ reaches for.
library;

import 'dart:async';

import '../booth.dart';
import '../deck.dart';
import '../mixer.dart' show EqSet;
import 'soft_takeover.dart';
import 'surface.dart';

/// What the binding needs from outside the booth: the crate.
class BindingHooks {
  const BindingHooks({this.load, this.browse});

  /// Put the crate's current record on [deck].
  final Future<void> Function(Deck deck)? load;

  /// Move the crate's cursor: [dy] rows down (negative is up), [dx] pages sideways.
  final void Function(int dx, int dy)? browse;
}

class BoothBinding {
  BoothBinding(this.booth, {this.hooks = const BindingHooks(), this.onLed, this.onNote, SoftTakeover? takeover})
      : takeover = takeover ?? SoftTakeover();

  final Booth booth;
  final BindingHooks hooks;

  /// A light to set. Called only when a light changes.
  final void Function(LedState led)? onLed;

  /// A line for the monitor: what the binding did with an event, or did not.
  final void Function(String note)? onNote;

  final SoftTakeover takeover;

  /// The pitch fader's reach either side of 0, cycled with shift + pitch reset.
  static const pitchRanges = [0.08, 0.16, 0.50];
  int pitchRangeIndex = 0;
  double get pitchRange => pitchRanges[pitchRangeIndex];

  /// Shift: a STOP button held on either deck.
  final _shiftHeld = <Side>{};
  bool get shift => _shiftHeld.isNotEmpty;
  bool _shiftUsed = false;

  /// Scratch mode: the jog wheel drags the record hard instead of nudging it.
  bool scratch = false;

  final _jog = {Side.a: _JogFeel(), Side.b: _JogFeel()};

  Deck deckOf(Side side) => side == Side.a ? booth.a : booth.b;

  // ------------------------------------------------------------------ in
  Future<void> handle(SurfaceEvent e) async {
    final where = Controls.deckOf(e.id);
    try {
      if (where != null) {
        await _deck(where.$1, where.$2, e);
      } else {
        await _global(e);
      }
    } catch (err) {
      onNote?.call('$e → $err');
    }
  }

  Future<void> _global(SurfaceEvent e) async {
    if (shift) _shiftUsed = true;
    switch (e.id) {
      case Controls.crossfader:
        if (_take(e, booth.crossfader)) await booth.setCrossfader(e.value);
      case Controls.master:
        if (_take(e, booth.master_)) await booth.setMaster(e.value);
      case Controls.scratch:
        if (e.pressed) {
          scratch = !scratch;
          _led(Controls.scratch, scratch);
          onNote?.call('scratch ${scratch ? 'on' : 'off'}');
        }
      case Controls.browseUp:
        if (e.pressed) _browse(0, -1);
      case Controls.browseDown:
        if (e.pressed) _browse(0, 1);
      case Controls.browseLeft:
        if (e.pressed) _browse(-1, 0);
      case Controls.browseRight:
        if (e.pressed) _browse(1, 0);
      case Controls.balance:
      case Controls.headMix:
      case Controls.mic:
        onNote?.call('${e.id}: not bound');
      case Controls.boardStop:
        if (e.pressed) await booth.board.stopAll();
      case Controls.boardLevel:
        // No soft take-over: a remote's fader shows the board's own level already,
        // and a desk's hardware fader for it is rare enough to be allowed its jump.
        await booth.board.setLevel(e.value);
      case Controls.boardBankPrev:
        if (e.pressed) await booth.board.stepBank(-1);
      case Controls.boardBankNext:
        if (e.pressed) await booth.board.stepBank(1);
      default:
        final pad = Controls.boardPadOf(e.id);
        if (pad != null) {
          // Down and up both: a hold pad plays for as long as the finger is on it.
          if (e.pressed) {
            await booth.board.press(booth.board.bank, pad - 1);
          } else {
            await booth.board.release(booth.board.bank, pad - 1);
          }
          return;
        }
        final bank = Controls.boardBankOf(e.id);
        if (bank != null) {
          if (e.pressed) await booth.board.showBank(bank - 1);
          return;
        }
        onNote?.call('${e.id}: unknown');
    }
  }

  Future<void> _deck(Side side, String name, SurfaceEvent e) async {
    final d = deckOf(side);
    if (name != Controls.stop && shift) _shiftUsed = true;
    switch (name) {
      case Controls.play:
        if (!e.pressed) return;
        if (shift) {
          await booth.startOnBeat(d);
        } else if (d.playing) {
          await d.pause();
        } else {
          await booth.play(d);
        }
      case Controls.cue:
        if (e.pressed) {
          if (shift) {
            await d.seekByHand(Duration.zero);
          } else {
            await d.cueDown();
          }
        } else {
          await d.cueUp();
        }
      case Controls.stop:
        if (e.pressed) {
          _shiftHeld.add(side);
          _shiftUsed = false;
        } else {
          _shiftHeld.remove(side);
          // A tap on STOP with nothing else: the record stops, back at its cue.
          if (!_shiftUsed && !shift) {
            if (d.playing) await d.pause();
            await d.placeByHand(d.cuePoint ?? Duration.zero);
          }
        }
      case Controls.sync:
        if (!e.pressed) return;
        if (shift) {
          await booth.align(d);
        } else {
          final why = d.synced ? null : booth.whyNotSync(d);
          if (why != null) {
            onNote?.call('sync ${side.name}: $why');
          } else {
            await booth.setSync(d, !d.synced);
          }
        }
      case Controls.keylock:
        if (e.pressed) await booth.setKeylock(d, !d.keylock);
      case Controls.pitchReset:
        if (!e.pressed) return;
        if (shift) {
          pitchRangeIndex = (pitchRangeIndex + 1) % pitchRanges.length;
          takeover.drop(Controls.deck(Side.a, Controls.pitch));
          takeover.drop(Controls.deck(Side.b, Controls.pitch));
          onNote?.call('pitch range ±${(pitchRange * 100).round()}%');
        } else {
          await booth.pitchByHand(d, 1.0);
        }
      case Controls.pitch:
        final sw = (((d.pitch - 1) / (2 * pitchRange)) + 0.5).clamp(0.0, 1.0);
        if (!_take(e, sw)) return;
        var rate = 1 + (e.value - 0.5) * 2 * pitchRange;
        if ((e.value - 0.5).abs() < 0.005) rate = 1.0;
        await booth.pitchByHand(d, rate);
      case Controls.jog:
        _jog[side]!.turn(d, e.value, scratch: scratch, shift: shift);
      case Controls.load:
        if (!e.pressed) return;
        final load = hooks.load;
        if (load == null) {
          onNote?.call('load ${side.name}: no crate here');
        } else {
          await load(d);
        }
      case Controls.prev:
      case Controls.next:
        if (!e.pressed) return;
        final bars = shift ? 8 : 1;
        final by = d.beatInRecord * 4 * bars;
        await booth.nudge(d, name == Controls.prev ? -by : by);
      case Controls.volume:
        if (_take(e, booth.gainOf(d))) await booth.setGain(d, e.value);
      case Controls.gain:
        // The knob over the fader is the filter: centre is off.
        final sw = (booth.filters[d] ?? 0) / 2 + 0.5;
        if (!_take(e, sw)) return;
        var f = (e.value - 0.5) * 2;
        if (f.abs() < 0.06) f = 0;
        await booth.setFilter(d, f);
      case Controls.eqLow:
      case Controls.eqMid:
      case Controls.eqHigh:
        final eq = booth.eqOf(d);
        final band = switch (name) { Controls.eqLow => 0, Controls.eqMid => 1, _ => 2 };
        final now = switch (band) { 0 => eq.low, 1 => eq.mid, _ => eq.high };
        // A killed band's knob reads where it would be unkilled: turning it is taking
        // the band back, not nudging a value nobody can hear.
        final sw = now <= EqSet.killed ? 0.5 : EqSet.knobOf(now);
        if (!_take(e, sw)) return;
        var t = e.value;
        if ((t - 0.5).abs() < 0.012) t = 0.5;
        final db = EqSet.dbOf(t);
        await booth.setEq(d, switch (band) { 0 => eq.withLow(db), 1 => eq.withMid(db), _ => eq.withHigh(db) });
      case Controls.killLow:
      case Controls.killMid:
      case Controls.killHigh:
        if (!e.pressed) return;
        final eq = booth.eqOf(d);
        final (band, on) = switch (name) {
          Controls.killLow => (0, eq.lowKilled),
          Controls.killMid => (1, eq.midKilled),
          _ => (2, eq.highKilled),
        };
        await booth.kill(d, band, !on);
      case Controls.pfl:
      case Controls.source:
      case Controls.fx:
        onNote?.call('${e.id}: not bound');
      default:
        final pad = Controls.padOf(name);
        if (pad != null) {
          await _pad(d, pad, e);
        } else {
          onNote?.call('${e.id}: unknown');
        }
    }
  }

  /// Pads 1–4 are hot cues, 5 and 6 loop in and out. Shift clears a cue, halves the
  /// loop (5) or lets it go (6).
  Future<void> _pad(Deck d, int n, SurfaceEvent e) async {
    if (!e.pressed) return;
    switch (n) {
      case 5:
        shift ? d.halveLoop() : d.loopIn();
      case 6:
        shift ? d.unloop() : d.loopOut();
      default:
        if (shift) {
          d.hotCues.remove(n);
          d.changed();
        } else if (d.hotCues.containsKey(n)) {
          await d.jumpCue(n);
        } else {
          d.setCue(n);
        }
    }
  }

  void _browse(int dx, int dy) {
    final b = hooks.browse;
    if (b == null) {
      onNote?.call('browse: no crate here');
    } else {
      b(dx, dy);
    }
  }

  /// Soft take-over for a positional control; anything else goes straight through.
  bool _take(SurfaceEvent e, double sw) {
    if (!e.kind.positional) return true;
    final ok = takeover.accept(e.id, e.value, sw);
    if (!ok) onNote?.call('${e.id}: waiting for the knob to reach ${sw.toStringAsFixed(2)}');
    return ok;
  }

  // ------------------------------------------------------------------ out
  final _lit = <String, bool>{};
  bool _attached = false;

  /// Start watching the booth for the lights, and say every light's state once.
  void attach() {
    if (_attached) return;
    _attached = true;
    booth.addListener(_lights);
    booth.moves.addListener(_lights);
    booth.a.addListener(_lights);
    booth.b.addListener(_lights);
    booth.board.addListener(_lights);
    _lit.clear();
    _lights();
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    booth.removeListener(_lights);
    booth.moves.removeListener(_lights);
    booth.a.removeListener(_lights);
    booth.b.removeListener(_lights);
    booth.board.removeListener(_lights);
    for (final j in _jog.values) {
      j.dispose();
    }
  }

  /// Every light as it should be now.
  List<LedState> lights() {
    final out = <LedState>[LedState(Controls.scratch, scratch)];
    for (final side in Side.values) {
      final d = deckOf(side);
      final eq = booth.eqOf(d);
      final looping = d.loopStart != null && d.loopEnd != null;
      String id(String n) => Controls.deck(side, n);
      out.addAll([
        LedState(id(Controls.play), d.playing),
        LedState(id(Controls.cue), d.cuePoint != null),
        LedState(id(Controls.sync), d.synced),
        LedState(id(Controls.keylock), d.keylock),
        LedState(id(Controls.pitchReset), (d.pitch - 1).abs() < 1e-4),
        LedState(id(Controls.killLow), eq.lowKilled),
        LedState(id(Controls.killMid), eq.midKilled),
        LedState(id(Controls.killHigh), eq.highKilled),
        for (var n = 1; n <= 4; n++) LedState(id(Controls.pad(n)), d.hotCues.containsKey(n)),
        LedState(id(Controls.pad(5)), d.loopOpen || looping),
        LedState(id(Controls.pad(6)), looping),
        LedState(id(Controls.load), false),
        LedState(id(Controls.pfl), false),
        LedState(id(Controls.source), false),
      ]);
    }
    // The board: the shown bank's pads, lit while they sound.
    final board = booth.board;
    for (var n = 1; n <= 16; n++) {
      out.add(LedState(Controls.boardPad(n), board.stateOf(board.bank, n - 1).sounding));
    }
    out.add(LedState(Controls.boardStop, board.anySounding));
    return out;
  }

  void _lights() {
    for (final l in lights()) {
      _led(l.id, l.on);
    }
  }

  void _led(String id, bool on) {
    if (_lit[id] == on) return;
    _lit[id] = on;
    onLed?.call(LedState(id, on));
  }
}

/// The jog wheel's feel.
///
/// Parked, a tick moves the needle a little (a lot, with shift). Playing, the wheel
/// bends the tempo for as long as it turns — gently in nudge mode, hard in scratch
/// mode — and the record settles back to its pitch when the hand comes off. No
/// reverse: the engine plays forwards only.
class _JogFeel {
  static const parkedTick = Duration(milliseconds: 20);
  static const parkedTickShift = Duration(milliseconds: 250);
  static const settleAfter = Duration(milliseconds: 90);

  double _velocity = 0;
  Timer? _settle;
  Deck? _bent;

  void turn(Deck d, double ticks, {required bool scratch, required bool shift}) {
    if (!d.playing) {
      unawaited(d.nudgeByHand((shift ? parkedTickShift : parkedTick) * ticks));
      return;
    }
    // Ticks arrive in bursts; a leaky sum reads the speed of the hand.
    _velocity = _velocity * 0.6 + ticks;
    final k = scratch ? 0.06 : 0.008;
    final rate = (d.pitch * (1 + k * _velocity)).clamp(0.5, 2.0);
    _bent = d;
    unawaited(d.bend(rate));
    _settle?.cancel();
    _settle = Timer(settleAfter, _rest);
  }

  void _rest() {
    _velocity = 0;
    final d = _bent;
    _bent = null;
    if (d != null) unawaited(d.bend(d.pitch));
  }

  void dispose() {
    _settle?.cancel();
    if (_bent != null) _rest();
  }
}
