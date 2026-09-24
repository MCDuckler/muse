import 'dart:io';

import 'helper_files.dart';
import 'status.dart';

/// The windowless fetcher, from the app's side: whether there is one, starting it,
/// stopping it, and having it start by itself when somebody logs in.
///
/// It is a program of its own that ships beside the app — see bin/wetowl_fetch.dart for
/// why — and everything said to it is said through files in the app's own folder, so
/// there is nothing here to get wrong about pipes, ports or process handles, and the
/// app can be shut and opened again without the fetcher noticing.
class BackgroundFetcher {
  BackgroundFetcher({
    required this.files,
    File? helper,
    Directory? autostartDir,
    Map<String, String>? environment,
  })  : helper = helper ?? _beside(),
        _env = environment ?? Platform.environment,
        _autostartDir = autostartDir;

  final HelperFiles files;

  /// The program. Beside the app's own, which is where the build puts it.
  final File helper;
  final Map<String, String> _env;
  final Directory? _autostartDir;

  static File _beside() {
    final dir = File(Platform.resolvedExecutable).parent.path;
    return File('$dir${Platform.pathSeparator}${Platform.isWindows ? 'wetowl-fetch.exe' : 'wetowl-fetch'}');
  }

  /// A copy of the app run out of a build folder has no helper beside it, and then
  /// there is no such thing as fetching in the background: the switch is not shown.
  Future<bool> get available => helper.exists();

  Future<FetchStatus?> status() => files.readStatus();

  /// Alive: it has said something in the last twenty seconds, and it says something
  /// every five.
  Future<bool> get alive async => (await status())?.fresh() ?? false;

  /// Tell it what to do and see that it is running. Safe to call when it already is:
  /// the file is rewritten, which it reads, and a second copy of it finds the lock taken
  /// and leaves.
  Future<void> start(
      {required String server,
      required String token,
      required int slots,
      bool fetch = true,
      bool split = true}) async {
    await files.writeConfig(HelperConfig(
      on: true,
      server: server,
      token: token,
      slots: slots,
      stamp: DateTime.now().millisecondsSinceEpoch,
      fetch: fetch,
      split: split,
    ));
    if (await alive) return;
    // Detached: not the app's child, so it outlives it, and on Windows with no console
    // window of its own.
    await Process.start(helper.path, ['--config', files.config.path],
        mode: ProcessStartMode.detached);
  }

  /// Switched off in the file, which it looks at every three seconds. It gives back
  /// what it was holding and goes. The token goes out of the file with it.
  Future<void> stop() async {
    final now = await files.readConfig();
    await files.writeConfig(HelperConfig(
      on: false,
      server: now?.server ?? '-',
      token: '-',
      slots: now?.slots ?? 3,
    ));
  }

  Future<void> setSlots(int slots) async {
    final now = await files.readConfig();
    if (now == null || !now.on) return;
    await files.writeConfig(HelperConfig(
        on: true,
        server: now.server,
        token: now.token,
        slots: slots,
        stamp: now.stamp,
        fetch: now.fetch,
        split: now.split));
  }

  // ------------------------------------------------------------ starting at login
  //
  // The plain way on each system, and nothing installed to do it: a .desktop file in
  // the autostart folder every Linux desktop reads, and on Windows a three-line script
  // in the Startup folder — a script rather than a shortcut or a registry entry because
  // it is the one way to start a console program at login without a black window
  // flashing up, and because anybody can see it there and delete it.

  File get autostartFile {
    if (Platform.isWindows) {
      final dir = _autostartDir?.path ??
          '${_env['APPDATA']}\\Microsoft\\Windows\\Start Menu\\Programs\\Startup';
      return File('$dir\\wetowl-fetch.vbs');
    }
    final config = _env['XDG_CONFIG_HOME'];
    final dir = _autostartDir?.path ??
        '${config != null && config.isNotEmpty ? config : '${_env['HOME']}/.config'}/autostart';
    return File('$dir/wetowl-fetch.desktop');
  }

  /// What goes in the file. Out here so it can be read in a test without being written
  /// to somebody's real Startup folder.
  String autostartEntry({bool? windows}) {
    final exe = helper.path, config = files.config.path;
    if (windows ?? Platform.isWindows) {
      String q(String s) => '""${s.replaceAll('"', '')}""';
      return "' WetOwl: keeps fetching music for the house when the app is shut.\r\n"
          "' Made by WetOwl's \"This computer\" page; switch it off there, or delete this file.\r\n"
          'CreateObject("WScript.Shell").Run "${q(exe)} --config ${q(config)}", 0, False\r\n';
    }
    // The Desktop Entry spec's quoting: in double quotes, with these four escaped.
    String q(String s) => '"${s.replaceAllMapped(RegExp(r'["`$\\]'), (m) => '\\${m[0]}')}"';
    return '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=WetOwl music fetcher\n'
        'Comment=Keeps fetching music for the house when WetOwl is shut\n'
        'Exec=${q(exe)} --config ${q(config)}\n'
        'Terminal=false\n'
        'NoDisplay=true\n'
        'X-GNOME-Autostart-enabled=true\n';
  }

  Future<bool> get startsAtLogin => autostartFile.exists();

  Future<void> setStartsAtLogin(bool on) async {
    final f = autostartFile;
    if (!on) {
      if (await f.exists()) await f.delete();
      return;
    }
    await f.parent.create(recursive: true);
    await f.writeAsString(autostartEntry());
  }
}
