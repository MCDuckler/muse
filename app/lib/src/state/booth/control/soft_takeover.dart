/// Soft take-over for knobs and faders.
///
/// A controller's knobs are wherever they were left, and the software's values are
/// wherever *they* were left — set by a transition, a touch on the screen, the last
/// session. The first nudge of a knob must not yank the sound to the knob: it is
/// ignored until the knob has come close to the software's value, or crossed it.
/// Mixxx's rule, and the one every DJ program ends up with.
library;

class SoftTakeover {
  SoftTakeover({this.reach = 3 / 127});

  /// How close counts as "there": three steps of a 7-bit knob.
  final double reach;

  final _lastHardware = <String, double>{};
  final _taken = <String, bool>{};

  /// Whether the hardware's new position [hw] for [id] should be taken, given the
  /// software is at [sw] (both 0..1). Remembers the hardware's position either way.
  bool accept(String id, double hw, double sw) {
    final last = _lastHardware[id];
    _lastHardware[id] = hw;
    if (_taken[id] == true) {
      // Taken, and the software has not wandered off since: it is the knob's.
      if (last != null && (last - sw).abs() <= reach * 2) return true;
      _taken[id] = false;
    }
    final near = (hw - sw).abs() <= reach;
    final crossed = last != null && ((last <= sw && hw >= sw) || (last >= sw && hw <= sw));
    if (near || crossed) {
      _taken[id] = true;
      return true;
    }
    return false;
  }

  /// Forget a control: the next move is judged afresh.
  void drop(String id) {
    _lastHardware.remove(id);
    _taken.remove(id);
  }

  void clear() {
    _lastHardware.clear();
    _taken.clear();
  }
}
