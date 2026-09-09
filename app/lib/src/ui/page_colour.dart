import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// Tell the browser what colour the app is.
///
/// On a phone this is not decoration. An installed web app has strips at the top and
/// the bottom that the page does not draw — the clock and the battery live up there —
/// and the system paints them from the page's declared colour. With nothing declared
/// it paints white, so muse in a dark palette came up with a bright band across the
/// top of the screen.
///
/// The palettes make this a moving target: the right colour is whichever ground is on
/// now, so it is written whenever that changes rather than set once in the HTML.
void setPageColour(Color colour) {
  if (!kIsWeb) return;
  final hex = '#${(colour.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  try {
    final document = web.document;
    for (final name in const ['theme-color']) {
      var meta = document.querySelector('meta[name="$name"]') as web.HTMLMetaElement?;
      if (meta == null) {
        meta = document.createElement('meta') as web.HTMLMetaElement;
        meta.name = name;
        document.head?.append(meta);
      }
      meta.content = hex;
    }
    // The strips are the page's own background where the app does not reach.
    (document.documentElement as web.HTMLElement?)?.style.backgroundColor = hex;
    document.body?.style.backgroundColor = hex;
  } catch (_) {
    // A browser that will not let us near its head is not a reason to fail to start.
  }
}
