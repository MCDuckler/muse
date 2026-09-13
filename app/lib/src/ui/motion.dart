import 'package:flutter/material.dart';

/// How long things take, and how they get there.
///
/// Three durations and three curves for the whole app. Not because more would be
/// wrong, but because the alternative — a number chosen at each call site — is how an
/// app ends up with a 150ms fade next to a 400ms one doing the same job, which reads
/// as carelessness even to somebody who could not say why.
class Motion {
  /// A state change you should barely notice: an icon swapping, a colour settling.
  static const quick = Duration(milliseconds: 130);

  /// The default. Something appearing, moving or growing where you are looking.
  static const base = Duration(milliseconds: 220);

  /// Something travelling a long way across the screen, or a whole page changing.
  static const slow = Duration(milliseconds: 340);

  /// Arriving: fast at first and easing in to a stop, which is what a thing that has
  /// been thrown does.
  static const enter = Curves.easeOutCubic;

  /// Leaving: the other way round. Something going away should not linger.
  static const exit = Curves.easeInCubic;

  /// Both ends eased, for anything that moves and then comes back.
  static const both = Curves.easeInOutCubic;

  /// A small overshoot, for the one or two things that should feel springy — a heart
  /// being pressed, mostly. Used sparingly: everything bouncing is a toy.
  static const pop = Curves.easeOutBack;
}

/// Whether this phone has been asked to keep still.
///
/// Somebody who turns on "remove animations" in their accessibility settings is not
/// asking for a slightly shorter fade; they are asking for the screen to stop moving,
/// usually because movement makes them ill. Decorative motion checks this and does
/// nothing; motion that carries meaning — a sheet coming up, which says where it came
/// from — stays, which is what the platform itself does.
bool stillness(BuildContext context) =>
    MediaQuery.maybeOf(context)?.disableAnimations ?? false;

/// A duration that respects that: zero when the phone has asked for stillness.
Duration moving(BuildContext context, Duration wanted) =>
    stillness(context) ? Duration.zero : wanted;
