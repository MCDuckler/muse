import 'package:flutter/material.dart';

import '../api/client.dart';

/// The little message at the bottom, said quickly and in the app's own colours.
///
/// Material's default is four seconds of a white slab: long enough that three actions
/// in a row leave a queue of messages about things you did a while ago, and bright
/// enough in a dark app that it takes the eye off whatever it was confirming. Two
/// seconds is long enough to read six words, which is all any of these are.
///
/// A message with a button to press keeps a little longer — there is something to do
/// about it, and no time to do it is worse than no message.
SnackBar snack(
  Widget content, {
  SnackBarAction? action,
  Duration? duration,
  Color? backgroundColor,
}) =>
    SnackBar(
      content: content,
      action: action,
      duration: duration ?? (action == null ? kSnackShort : kSnackWithAction),
      backgroundColor: backgroundColor,
    );

/// What went wrong, said the way it was written rather than the way it was thrown.
///
/// An ApiException's toString is "ApiException(404): …", and the server's sentences are
/// written to be read by whoever is holding the phone — "nothing was added rather than
/// the wrong thing" is an explanation; "ApiException(404)" in front of it is a stack
/// trace with an explanation attached.
SnackBar problem(Object error, {SnackBarAction? action}) => snack(
      Text(error is ApiException ? error.message : '$error'),
      action: action,
      duration: kSnackWithAction,
    );

const kSnackShort = Duration(milliseconds: 2000);
const kSnackWithAction = Duration(milliseconds: 3500);
