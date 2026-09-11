import 'package:http/http.dart' as http;

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
final http.Client net = http.Client();
