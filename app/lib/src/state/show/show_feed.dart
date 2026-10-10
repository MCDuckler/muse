// Where a show's frames come from: the engine on the booth, or a recording played
// back. The stage and the lights read one of these and never the booth itself, so a
// recording looks exactly like a set to them.
import 'package:flutter/foundation.dart';

import 'show_events.dart';
import 'show_state.dart';

abstract class ShowFeed implements Listenable {
  /// The latest frame.
  ShowState get state;

  /// The moments, as they pass.
  Stream<ShowEvent> get events;
}
