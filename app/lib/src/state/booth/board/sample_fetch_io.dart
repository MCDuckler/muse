// A server sample's sound, brought to this device once and kept under the app's
// own directory, so a pad is a file on disk and a press is not a request.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../../api/client.dart';

Future<String?> Function(int id) sampleFetcher(ApiClient api) {
  final inFlight = <int, Future<String?>>{};
  return (id) => inFlight[id] ??= _fetch(api, id).whenComplete(() => inFlight.remove(id));
}

Future<String?> _fetch(ApiClient api, int id) async {
  try {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}samples');
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}$id.audio');
    if (file.existsSync() && file.lengthSync() > 0) return file.path;
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(api.sampleAudioUrl(id)));
      api.streamHeaders.forEach(request.headers.set);
      final response = await request.close();
      if (response.statusCode >= 400) {
        debugPrint('board: sample $id — the server said ${response.statusCode}');
        return null;
      }
      final part = File('${file.path}.part');
      final sink = part.openWrite();
      await response.forEach(sink.add);
      await sink.flush();
      await sink.close();
      await part.rename(file.path);
      return file.path;
    } finally {
      client.close();
    }
  } catch (e) {
    debugPrint('board: sample $id did not arrive — $e');
    return null;
  }
}

/// A sample forgotten: its file too.
Future<void> forgetSampleFile(int id) async {
  try {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}samples');
    final f = File('${dir.path}${Platform.pathSeparator}$id.audio');
    if (f.existsSync()) await f.delete();
  } catch (_) {}
}
