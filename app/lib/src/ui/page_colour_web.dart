import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// The browser's own idea of the page colour: a meta tag it reads, and the background
/// behind everything the app draws.
///
/// The palettes make this a moving target: the right colour is whichever ground is on
/// now, so it is written whenever that changes rather than set once in the HTML.
void setPageColour(Color colour) {
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
