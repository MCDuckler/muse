import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Signing in to YouTube Music, in the app, so nobody has to copy headers by hand.
///
/// YouTube has no way to ask for permission the way Spotify does — no consent screen a
/// third-party app can send you to for "read my library". What ytmusicapi uses instead
/// is the sign-in a browser already has, which until now meant opening developer tools
/// on a computer and pasting a block of request headers. This is a browser, in the app,
/// pointed at the same page: sign in as normal, and the cookie it ends up with is the
/// one that gets stored. Nothing is read from the page itself and no password passes
/// through here — Google's own form is what is on screen.
///
/// Only on a phone. A web build cannot see cookies for another site, which is the whole
/// point of the rule, so there the headers still have to be pasted.
bool get canSignInToYouTube =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// The platform's own cookie jar. Asking the page for `document.cookie` cannot see the
/// cookies marked HttpOnly, which is most of the ones a signed-in session is made of.
const _jar = MethodChannel('muse/cookies');

/// What YouTube Music needs to recognise a request as coming from a signed-in session.
const _needed = ['SAPISID', '__Secure-3PAPISID', '__Secure-1PAPISID'];

class YouTubeSignInPage extends StatefulWidget {
  const YouTubeSignInPage({super.key});

  @override
  State<YouTubeSignInPage> createState() => _YouTubeSignInPageState();
}

class _YouTubeSignInPageState extends State<YouTubeSignInPage> {
  late final WebViewController _web;
  bool _checking = false;
  String? _note;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // The desktop site: the phone one signs in the same way, but the library pages
      // ytmusicapi reads are the desktop ones and the cookie is the same either way.
      ..setUserAgent(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0 Safari/537.36')
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) => _lookForSignIn(),
      ))
      ..loadRequest(Uri.parse('https://music.youtube.com/'));
  }

  /// Has the browser got a signed-in session yet?
  ///
  /// Checked whenever a page finishes rather than by asking the person to tell us: the
  /// sign-in flow is several pages long and ends wherever Google decides, so the only
  /// reliable signal is the cookie appearing.
  Future<void> _lookForSignIn() async {
    if (_checking) return;
    _checking = true;
    try {
      final cookie = await _jar.invokeMethod<String>(
          'get', {'url': 'https://music.youtube.com'});
      final have = {
        for (final part in (cookie ?? '').split(';'))
          part.trim().split('=').first
      };
      if (cookie == null || !_needed.any(have.contains)) {
        if (mounted) setState(() => _note = 'Sign in to YouTube Music above.');
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pop(_headerBlock(cookie));
    } on PlatformException {
      if (mounted) setState(() => _note = 'This device cannot read the sign-in.');
    } finally {
      _checking = false;
    }
  }

  /// The cookie, written the way ytmusicapi wants to be handed a sign-in.
  String _headerBlock(String cookie) {
    return 'cookie: $cookie\n'
        'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0 Safari/537.36\n'
        'origin: https://music.youtube.com\n'
        'x-goog-authuser: 0\n'
        'accept-language: en-US,en;q=0.9';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in to YouTube Music'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'Done signing in',
            onPressed: _lookForSignIn,
          ),
        ],
        bottom: _note == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(28),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8, left: 16, right: 16),
                  child: Text(_note!,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              ),
      ),
      body: WebViewWidget(controller: _web),
    );
  }
}
