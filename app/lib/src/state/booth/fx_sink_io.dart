import 'dart:io';
import 'dart:typed_data';

/// A rendered sound as a file under a directory of this session's own, handed to the
/// player as a path.
///
/// A temporary file rather than a data: URL because mpv, which is what plays this on
/// a desk, will not take one — and a sixteen-second riser is three megabytes, which
/// is a great deal of base64 to push through a platform channel four bars before it
/// has to make a sound.
Directory? _dir;
final _kept = <String, String>{};

Future<String?> fxSource(Uint8List wav, String key) async {
  final was = _kept[key];
  if (was != null && File(was).existsSync()) return was;
  final dir = _dir ??= await Directory.systemTemp.createTemp('wetowl-fx');
  final path = '${dir.path}/$key.wav';
  await File(path).writeAsBytes(wav, flush: true);
  _kept[key] = path;
  return path;
}

/// The session's sounds, thrown away — on the way out, and whenever the set is over.
void fxForget() {
  _kept.clear();
  try {
    _dir?.deleteSync(recursive: true);
  } on FileSystemException {
    // A file still open in the engine: the system's own temp sweep gets it.
  }
  _dir = null;
}
