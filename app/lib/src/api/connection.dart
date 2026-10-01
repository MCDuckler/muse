import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Whether the last thing the app asked the server actually arrived.
///
/// Until now "the server is not there" was something the app found out once per
/// request, separately, in whichever screen happened to ask: a spinner that never
/// stopped on one page, a red line of text on another, a snack bar on a third, and
/// nothing anywhere saying the single true thing — that the phone cannot reach the
/// box, and that nothing is going to work until it can.
///
/// One flag, flipped by the only code that can know: the layer that puts requests on
/// the wire and either gets an answer or does not.
final ValueNotifier<bool> serverIsThere = ValueNotifier<bool>(true);

/// One HTTP client for the whole app.
///
/// package:http's top-level helpers — `http.get(...)`, `http.post(...)` — open a
/// connection, make the one request and close it again. On a phone that is a fresh TCP
/// connection and a fresh TLS handshake for every call the app makes and for every
/// cover in a list: three round trips before a byte of the picture moves, two hundred
/// times over while a queue's artwork warms.
///
/// A client that is kept keeps its connections, so the second request onwards goes
/// down a socket that is already open. Nothing else about the calls changes.
///
/// On the web this is the browser's own fetch, which was already pooling; the win is
/// on the phone.
http.Client net = _Watched(http.Client());

/// Put the ear on some other client — for tests, which supply their own answers but
/// still want the watching that the real one does.
http.Client watching(http.Client inner) => _Watched(inner);

/// The same client, with an ear on whether anything is getting through.
class _Watched extends http.BaseClient {
  _Watched(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    try {
      final response = await _inner.send(request);
      // An answer of any kind means the box is reachable. A 404 or a 500 is the
      // server having an opinion, which is a different problem and one the caller
      // already handles.
      serverIsThere.value = true;
      return response;
    } catch (_) {
      // Anything thrown here is the request not arriving: no route, no DNS, no TLS,
      // nothing listening. Errors *about* a response are raised further up, after
      // this has already said the connection was fine.
      serverIsThere.value = false;
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}

/// Whether [net] is the app's own client, rather than one a test put in its place.
bool _netIsOurs = true;

/// Hand the app a different client, and take it back again.
///
/// For tests, which need the answers without a socket: a screen that talks to the
/// server can then be driven entirely on the test's own clock, where a real request
/// would sit unfinished until somebody let the real event loop run.
void useThisClientInstead(http.Client other) {
  net = other;
  _netIsOurs = false;
}

/// Start over with new connections, after the app has been away.
///
/// The kept connections are what make the second request fast, and they are exactly
/// what does not survive a phone putting the app to sleep: the box closes them after a
/// while, iOS takes the sockets of an app it suspends, and nobody tells the pool. The
/// first requests on coming back went down those dead sockets — covers that "did not
/// arrive", and the "Can't reach the server" line with the server right there.
///
/// The old client is closed gently: idle connections go now, anything still in flight
/// finishes on it.
void freshConnections() {
  if (kIsWeb || !_netIsOurs) return;
  final old = net;
  net = _Watched(http.Client());
  old.close();
}
