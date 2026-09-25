import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// A rendered sound as a blob the page owns, handed to the element as a URL.
final _kept = <String, String>{};

Future<String?> fxSource(Uint8List wav, String key) async {
  final was = _kept[key];
  if (was != null) return was;
  final blob = web.Blob([wav.toJS].toJS, web.BlobPropertyBag(type: 'audio/wav'));
  final url = web.URL.createObjectURL(blob);
  _kept[key] = url;
  return url;
}

/// The blobs let go of: a browser keeps one alive until the page says otherwise, and
/// a long set is a great many megabytes of noise.
void fxForget() {
  for (final url in _kept.values) {
    web.URL.revokeObjectURL(url);
  }
  _kept.clear();
}
