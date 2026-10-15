// Secrets out of a line on its way into a log: a bearer token, and the keys that ride
// in a stream's address (?k=) or a link's (?t=). Both logs travel — the file is what
// gets attached when something goes wrong, the playback log is sent to the server —
// and a dart:io error's message carries the whole address it failed on, keys and all.
final _bearer = RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+');
final _key = RegExp(r'([?&](?:k|t|token)=)[^&\s"]+');

String redact(String line) =>
    line.replaceAll(_bearer, 'Bearer ***').replaceAllMapped(_key, (m) => '${m[1]}***');
