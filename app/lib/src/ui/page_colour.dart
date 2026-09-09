import 'package:flutter/material.dart';

import 'page_colour_none.dart'
    if (dart.library.js_interop) 'page_colour_web.dart' as impl;

/// Tell the browser what colour the app is.
///
/// On a phone this is not decoration. An installed web app has strips at the top and
/// the bottom that the page does not draw — the clock and the battery live up there —
/// and the system paints them from the page's declared colour. With nothing declared
/// it paints white, so muse in a dark palette came up with a bright band across the
/// top of the screen.
///
/// The implementation is chosen at compile time rather than guarded with `kIsWeb`:
/// `package:web` is built on `dart:js_interop`, which does not exist on Android at
/// all, so importing it unconditionally fails the APK build long before any runtime
/// check could have helped.
void setPageColour(Color colour) => impl.setPageColour(colour);
