import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

/// What a tap feels like.
///
/// A phone can answer a finger before the screen has finished changing, and for an app
/// that is mostly a list of things to press, that answer is most of what "responsive"
/// means. This is the whole of it in one place, so the app has a vocabulary — a tap is
/// a tap everywhere, a commitment feels different from a choice — rather than a
/// scattering of HapticFeedback calls that drift apart.
///
/// Silent everywhere it should be: a browser has no motor, a desktop has no motor, and
/// somebody who has turned it off has said what they want.
enum Feel {
  /// Something ordinary happened: a row opened, a button did its job.
  tap,

  /// Picking one thing out of several — a chip, a row joining a selection, a tab.
  pick,

  /// A decision that changes something: play, pause, skip, save, join.
  commit,

  /// The line a gesture crosses on its way to doing something, felt at the line
  /// rather than when the finger lifts. This is the one that makes a swipe feel
  /// mechanical instead of guessed at.
  edge,

  /// Something refused, failed, or is about to be destructive.
  warn,
}

/// The buzz, where there is one to give.
class Haptics {
  /// Off switches the lot. Held here rather than read from the app's state on every
  /// press: this is called from inside gesture handlers, where reaching for a provider
  /// is both slow and sometimes impossible.
  static bool enabled = true;

  /// Android and iOS have the motor. A browser tab has `navigator.vibrate`, which is a
  /// buzz the length of a text message rather than a tick, and a desktop has nothing —
  /// so on both of those this does nothing at all rather than something wrong.
  static bool get available =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// The last one, so a list being flung past a hundred rows is not a hundred ticks.
  ///
  /// A motor that is already moving cannot give a second distinct tick anyway: what it
  /// gives is a longer buzz, which reads as the phone complaining.
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  static const _apart = Duration(milliseconds: 60);

  /// Counted so tests can watch for it without a platform.
  static int count = 0;
  static Feel? lastFeel;

  static void of(Feel feel) {
    lastFeel = feel;
    if (!enabled || !available) return;
    final now = DateTime.now();
    if (now.difference(_last) < _apart) return;
    _last = now;
    count++;
    switch (feel) {
      case Feel.tap:
        HapticFeedback.lightImpact();
      case Feel.pick:
        HapticFeedback.selectionClick();
      case Feel.commit:
        HapticFeedback.mediumImpact();
      case Feel.edge:
        HapticFeedback.selectionClick();
      case Feel.warn:
        HapticFeedback.heavyImpact();
    }
  }

  /// For tests: forget what happened.
  static void forget() {
    count = 0;
    lastFeel = null;
    _last = DateTime.fromMillisecondsSinceEpoch(0);
  }
}

/// Shorthand, because this is called from inside `onTap:` closures all over the app
/// and `Haptics.of(Feel.tap)` reads like ceremony at the front of a one-line callback.
void feel(Feel what) => Haptics.of(what);

/// Do the thing, and say so with a tick.
///
/// Wrapping rather than two statements: the point of a callback feeling like something
/// is that it happens with the action, and a separate line is a line somebody forgets
/// to move when the action does.
VoidCallback felt(Feel what, VoidCallback? action) => () {
      if (action == null) return;
      Haptics.of(what);
      action();
    };
