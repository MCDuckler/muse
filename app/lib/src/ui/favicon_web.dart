import 'package:web/web.dart' as web;

/// Put the server's icon on the page, at an address that changes when it does.
///
/// The tab icon and the one a phone puts on its home screen are cached by the browser
/// against the URL they came from — so an icon that changes without its address
/// changing is an icon nobody ever sees change. The app asks the server what the icon
/// is now and writes the answer, signature and all, into the page.
void wearTheIcon(String url, String appleTouchUrl) {
  try {
    final document = web.document;
    for (final (selector, rel, href) in [
      ('link[rel="icon"]', 'icon', url),
      ('link[rel="apple-touch-icon"]', 'apple-touch-icon', appleTouchUrl),
    ]) {
      var link = document.querySelector(selector) as web.HTMLLinkElement?;
      if (link == null) {
        link = document.createElement('link') as web.HTMLLinkElement;
        link.rel = rel;
        document.head?.append(link);
      }
      link.href = href;
    }
  } catch (_) {
    // A page that will not have its head written on still plays music.
  }
}
