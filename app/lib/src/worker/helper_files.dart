import 'dart:convert';
import 'dart:io';

import 'status.dart';

/// What the app tells the windowless fetcher.
class HelperConfig {
  const HelperConfig({
    required this.on,
    required this.server,
    required this.token,
    this.slots = 3,
    this.stamp = 0,
  });

  final bool on;
  final String server;
  final String token;
  final int slots;

  /// Changed whenever the app wants another go made of it — "Look again", after a
  /// missing program has been installed.
  final int stamp;

  Map<String, dynamic> toJson() =>
      {'on': on, 'server': server, 'token': token, 'slots': slots, 'stamp': stamp};

  static HelperConfig? fromJson(Object? j) {
    if (j is! Map) return null;
    final server = j['server'], token = j['token'];
    if (server is! String || token is! String || server.isEmpty || token.isEmpty) return null;
    return HelperConfig(
      on: j['on'] == true,
      server: server,
      token: token,
      slots: ((j['slots'] as num?)?.toInt() ?? 3).clamp(1, 6).toInt(),
      stamp: (j['stamp'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The handful of files the app and the windowless fetcher share, all in one folder:
/// the app's own, under the user's account.
class HelperFiles {
  HelperFiles(this.dir);
  final Directory dir;

  File _in(String name) => File('${dir.path}${Platform.pathSeparator}$name');

  File get config => _in('fetcher.json');
  File get status => _in('fetcher-status.json');
  File get lock => _in('fetching.lock');
  Directory get tools => Directory('${dir.path}${Platform.pathSeparator}tools');

  Future<HelperConfig?> readConfig() async => HelperConfig.fromJson(await _read(config));
  Future<FetchStatus?> readStatus() async => FetchStatus.fromJson(await _read(status));

  /// The token in it is this device's sign-in, so the file is the user's alone where
  /// the system has a way of saying so. (On Windows the folder already is.)
  Future<void> writeConfig(HelperConfig c) => _write(config, c.toJson(), private: true);

  Future<void> writeStatus(FetchStatus s) => _write(status, s.toJson());

  Future<Object?> _read(File f) async {
    try {
      return jsonDecode(await f.readAsString());
    } catch (_) {
      // Not there, or caught half way through being replaced: the same as nothing.
      return null;
    }
  }

  /// Written beside and moved into place, so a reader never sees half a file. A
  /// [private] one is made empty and closed to everybody else *before* anything goes in
  /// it: a file that is created with the token already inside and locked down after is
  /// readable by the whole machine for the moment in between.
  Future<void> _write(File f, Object what, {bool private = false}) async {
    try {
      await dir.create(recursive: true);
      final beside = File('${f.path}.new');
      if (private && !Platform.isWindows) {
        await beside.writeAsString('', flush: true);
        final r = await Process.run('chmod', ['600', beside.path]);
        if (r.exitCode != 0) throw FileSystemException('could not make it private', beside.path);
      }
      await beside.writeAsString(jsonEncode(what), flush: true);
      await beside.rename(f.path);
    } catch (_) {
      // A status nobody could write is a status nobody reads; the fetching goes on. A
      // config that could not be made private is not written at all.
    }
  }
}
