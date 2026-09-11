import 'dart:async';

/// Fold a burst of "something changed" into one call.
///
/// Download progress arrives several times a second for every track being fetched at
/// once, and each report used to rebuild every screen listening to the app — the bar
/// at the bottom of every page, the queue, and the ring on every row in view. Nothing
/// on screen moves faster than a few times a second, so the reports are gathered up
/// and told once.
///
/// The first call goes straight through: a progress ring that waits a quarter of a
/// second to appear is a quarter of a second of nothing happening.
class Coalesce {
  Coalesce(this.window, this.run);

  /// How long to gather up calls before running again.
  final Duration window;
  final void Function() run;

  Timer? _waiting;
  DateTime? _lastRun;
  bool _stopped = false;

  /// Ask for [run] to happen. It happens now if the last one was long enough ago, and
  /// otherwise once at the end of the current window — never more often than that, and
  /// never dropped entirely.
  void call() {
    if (_stopped || _waiting != null) return;
    final since = _lastRun == null
        ? window
        : DateTime.now().difference(_lastRun!);
    if (since >= window) {
      _lastRun = DateTime.now();
      run();
      return;
    }
    _waiting = Timer(window - since, () {
      _waiting = null;
      if (_stopped) return;
      _lastRun = DateTime.now();
      run();
    });
  }

  void dispose() {
    _stopped = true;
    _waiting?.cancel();
    _waiting = null;
  }
}
