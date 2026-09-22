import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../api/connection.dart';

/// What is on the server, and whether it is newer than what is running.
class Release {
  const Release({
    required this.version,
    required this.build,
    required this.bytes,
    this.built,
  });

  final String version;

  /// The moment it was built, as `YYYYMMDDHHMM`. This is what "newer" means: a stamp
  /// cannot be forgotten to be bumped and is in order by construction, which a
  /// hand-written version number in a source file is not — the one this replaced said
  /// 0.1.0 for every build ever made.
  final String build;

  final int bytes;
  final String? built;

  factory Release.fromJson(Map<String, dynamic> j) => Release(
        version: (j['version'] ?? '?') as String,
        build: '${j['build'] ?? ''}',
        bytes: (j['bytes'] ?? 0) as int,
        built: j['built'] as String?,
      );

  bool isNewerThan(String mine) {
    final theirs = int.tryParse(build);
    if (theirs == null) return false;        // the server has nothing to offer
    final ours = int.tryParse(mine);
    // An app that does not know when it was made was made before any of this existed,
    // which is exactly what every copy installed by hand up to now is. Refusing to
    // offer an update to those was a trap with no way out of it: the first stamped
    // build could never be reached from an unstamped one, so the feature could not
    // install the version that makes the feature work.
    if (ours == null) return true;
    return theirs > ours;
  }

  /// Whether we can say anything about what is running, as opposed to only about what
  /// is on the server.
  static bool knows(String mine) => int.tryParse(mine) != null;

  String get size => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Where an update is up to.
enum Updating { idle, checking, ready, downloading, waiting, failed }

/// Fetching a new version of the app, and asking to install it.
///
/// Worth saying plainly what this can and cannot do: Android will not let anything but
/// a device owner install software without a person saying yes. So the app does
/// everything up to that — notices there is a new version, fetches it, checks it
/// arrived whole — and then asks, once, with one tap. What it does not do is update
/// itself while nobody is looking, and there is no way for it to.
class Updates extends ChangeNotifier {
  Updates({required this.baseUrl, required this.running});

  /// The server the app is talking to. The APK sits beside the web app it came from,
  /// so there is nothing to configure and nowhere else to look.
  String baseUrl;

  /// The build this app was made from, or empty when it was not made by the publisher.
  ///
  /// Not final: a desktop build carries its stamp in a file beside the program as well
  /// as in the binary, and a copy that was built without the define can still read it
  /// from there. See [look].
  String running;

  static const _channel = MethodChannel('muse/install');

  /// Whether this app can bring a newer build of itself in: the phone, through the
  /// system's installer, and the desktop, by swapping its own files. Not the browser,
  /// which reloads; not the iPhone, which is signed by somebody else.
  static bool get supported => android || desktop != null;

  static bool get android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Updating state = Updating.idle;
  Release? release;
  double progress = 0;
  String? trouble;
  File? _fetched;

  bool get available => release != null && release!.isNewerThan(running);

  /// What the server has, whoever is asking.
  ///
  /// Separate from [look] because it is not about updating: the web app on a laptop
  /// has no update to offer and still wants to say "here is the Android app, and here
  /// is how big it is".
  static Future<Release?> published(String baseUrl) async {
    try {
      final r = await net
          .get(Uri.parse('$baseUrl/muse.apk.json'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final decoded = jsonDecode(r.body);
      return decoded is Map<String, dynamic> ? Release.fromJson(decoded) : null;
    } catch (_) {
      // No manifest, no signal, an older server: nothing to say.
      return null;
    }
  }

  /// Where the file itself is. One link, the same one the browser downloads.
  static String apkUrl(String baseUrl) => '$baseUrl/muse.apk';

  // ---------------- the desktop builds ----------------
  //
  // A zip for Windows and a tarball for Linux, beside the others. Nothing installs
  // itself here either: the app says a newer one is there and opens the download.

  /// Which desktop build this is running as, or null when it is not one.
  static String? get desktop => kIsWeb
      ? null
      : switch (defaultTargetPlatform) {
          TargetPlatform.windows => 'windows',
          TargetPlatform.linux => 'linux',
          _ => null,
        };

  static String desktopUrl(String baseUrl, String os) =>
      os == 'windows' ? '$baseUrl/wetowl-windows.zip' : '$baseUrl/wetowl-linux.tar.gz';

  static Future<Release?> publishedDesktop(String baseUrl, String os) async {
    try {
      final r = await net
          .get(Uri.parse('$baseUrl/wetowl-$os.json'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final decoded = jsonDecode(r.body);
      return decoded is Map<String, dynamic> ? Release.fromJson(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  // ---------------- the iPhone build ----------------
  //
  // Everything above is about an app that can install itself, once somebody says yes.
  // iOS has no such thing: an unsigned build is signed on the phone by SideStore or
  // AltStore, which is a different app, so all this side can do is say what is on the
  // server and hand the link over. That is still worth doing — the alternative is
  // finding a private repository's releases page on a phone.

  /// The iPhone build the server is offering, if any.
  static Future<Release?> publishedIpa(String baseUrl) async {
    try {
      final r = await net
          .get(Uri.parse('$baseUrl/wetowl.ipa.json'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final decoded = jsonDecode(r.body);
      return decoded is Map<String, dynamic> ? Release.fromJson(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  static String ipaUrl(String baseUrl) => '$baseUrl/wetowl.ipa';

  /// The same file, addressed to whichever sideloader is installed.
  ///
  /// Both of them register a URL scheme that takes an https link and does the fetching
  /// and signing themselves; handing the plain link to Safari instead gets a file in
  /// Downloads that nothing on the phone will open. SideStore first because it is the
  /// one that works without a computer on the same network.
  static List<Uri> sideloaders(String baseUrl) {
    final url = Uri.encodeComponent(ipaUrl(baseUrl));
    return [
      Uri.parse('sidestore://install?url=$url'),
      Uri.parse('altstore://install?url=$url'),
    ];
  }

  /// The sideloaders' own list of WetOwl builds.
  ///
  /// Adding this once is the difference between a download and an app that updates
  /// itself: the build sits in SideStore's Browse tab from then on, and every publish
  /// after this one shows up there as an update rather than as a link somebody has to
  /// be sent again. It is as close to the Android row as iOS gets without an Apple
  /// developer account.
  static String sourceUrl(String baseUrl) => '$baseUrl/wetowl-source.json';

  /// That list, addressed to whichever sideloader is installed.
  static List<Uri> sourceAdders(String baseUrl) {
    final url = Uri.encodeComponent(sourceUrl(baseUrl));
    return [
      Uri.parse('sidestore://source?url=$url'),
      Uri.parse('altstore://source?url=$url'),
    ];
  }

  /// Whether this device is the one that could use an ipa.
  static bool get iphone =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Look, quietly. Anything that goes wrong here is not worth a word: an update
  /// nobody knew about cannot be missed.
  Future<void> look() async {
    if (!supported || state == Updating.downloading) return;
    state = Updating.checking;
    notifyListeners();
    final os = desktop;
    if (os != null) {
      if (!Release.knows(running)) running = await stampBeside() ?? running;
      release = await publishedDesktop(baseUrl, os) ?? release;
    } else {
      release = await published(baseUrl) ?? release;
    }
    state = available ? Updating.ready : Updating.idle;
    notifyListeners();
  }

  /// Fetch it, then ask to install it.
  Future<void> fetchAndOffer() async {
    final want = release;
    if (!supported || want == null || state == Updating.downloading) return;

    state = Updating.downloading;
    progress = 0;
    trouble = null;
    notifyListeners();

    try {
      final dir = Directory(
          '${(await getApplicationSupportDirectory()).path}/updates');
      await dir.create(recursive: true);
      // One file, replaced each time. Keeping every version ever fetched would quietly
      // fill the phone with sixty-megabyte copies of the same app.
      for (final old in dir.listSync()) {
        try {
          old.deleteSync(recursive: true);
        } catch (_) {}
      }
      final os = desktop;
      final into = File(os == null
          ? '${dir.path}/muse-${want.build}.apk'
          : '${dir.path}/wetowl-$os-${want.build}${os == 'windows' ? '.zip' : '.tar.gz'}');

      final request = http.Request(
          'GET', Uri.parse(os == null ? '$baseUrl/muse.apk' : desktopUrl(baseUrl, os)));
      final response = await http.Client().send(request);
      if (response.statusCode != 200) {
        throw HttpException('the server answered ${response.statusCode}');
      }
      final total = response.contentLength ?? want.bytes;
      final sink = into.openWrite();
      var had = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        had += chunk.length;
        if (total > 0) {
          final now = had / total;
          // Not on every chunk: this arrives in kilobytes and the bar is a few hundred
          // pixels wide.
          if (now - progress > 0.004 || now >= 1) {
            progress = now;
            notifyListeners();
          }
        }
      }
      await sink.close();

      final got = await into.length();
      // All there, and the right thing. Size is what catches a download cut short,
      // which is the failure that actually happens; anything worse than that — a file
      // altered on the way down — is caught by the installer itself, which checks the
      // signature before it installs anything and is not something this app could do
      // better.
      if (want.bytes > 0 && (got - want.bytes).abs() > 1024) {
        throw const FormatException('it did not all arrive');
      }

      _fetched = into;
      if (desktop != null) {
        // Unpacked now, while the app is still here to say what went wrong. The
        // swap itself waits for a word: it closes the window.
        _staged = await stageDesktop(into, Directory('${dir.path}/stage'));
      }
      state = Updating.waiting;
      notifyListeners();
      if (desktop == null) await offer();
    } catch (e) {
      trouble = '$e';
      state = Updating.failed;
      notifyListeners();
    }
  }

  /// Open the system installer on what was fetched — or, on a desk, close the app
  /// and let the new build take its place.
  Future<void> offer() async {
    final file = _fetched;
    if (!supported || file == null) return;
    if (desktop != null) return _applyDesktop();
    try {
      final allowed =
          await _channel.invokeMethod<bool>('allowed') ?? false;
      if (!allowed) {
        // The one setting that grants it, opened directly rather than described.
        await _channel.invokeMethod<void>('allow');
        return;
      }
      final opened =
          await _channel.invokeMethod<bool>('open', {'path': file.path}) ?? false;
      if (!opened) {
        trouble = 'the installer would not open';
        state = Updating.failed;
        notifyListeners();
      }
    } catch (e) {
      trouble = '$e';
      state = Updating.failed;
      notifyListeners();
    }
  }

  // ---------------- updating a desktop build in place ----------------
  //
  // The desktop build is a folder: the program, its libraries, its assets and the
  // fetcher beside it. Updating it is replacing that folder's contents with the next
  // build's — which the program cannot do to itself while it is running, on Windows
  // because the files are locked and on Linux because the running one would be
  // swapped out from under itself. So it does everything it can while running —
  // fetch, check, unpack — then writes a few lines of shell that wait for it to be
  // gone, copy the new build over the old, and start it again; starts them; and quits.

  Directory? _staged;

  /// Where this program is: the folder the build is.
  static Directory get installDir => File(Platform.resolvedExecutable).parent;

  /// The program's own file name in that folder.
  static String get exeName => Platform.isWindows ? 'wetowl.exe' : 'wetowl';

  /// The build stamp the build put beside the program, if it did.
  static Future<String?> stampBeside() async {
    try {
      final f = File('${installDir.path}${Platform.pathSeparator}build-stamp.txt');
      if (!await f.exists()) return null;
      final s = (await f.readAsString()).trim();
      return Release.knows(s) ? s : null;
    } catch (_) {
      return null;
    }
  }

  /// Whether the folder the program is in can be written to. A build unpacked into
  /// somebody's home can be; one an administrator put under /opt or Program Files
  /// cannot, and then the honest answer is the download.
  static Future<bool> canWriteInstallDir([Directory? dir]) async {
    final probe = File('${(dir ?? installDir).path}${Platform.pathSeparator}.wetowl-write-test');
    try {
      await probe.writeAsString('', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Unpack [archive] into [stage] and say where the build is inside it.
  ///
  /// The system's own tar, which every Linux has and Windows 10 has had since 2018 —
  /// and which reads a zip as well as a tarball — rather than a library for a thing
  /// that happens once a fortnight. Windows without it falls back to PowerShell.
  static Future<Directory> stageDesktop(File archive, Directory stage) async {
    if (await stage.exists()) await stage.delete(recursive: true);
    await stage.create(recursive: true);
    final zip = archive.path.endsWith('.zip');
    var r = await Process.run(
        'tar', [zip ? '-xf' : '-xzf', archive.path, '-C', stage.path]);
    if (r.exitCode != 0 && zip && Platform.isWindows) {
      r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        'Expand-Archive -Force -LiteralPath "${archive.path}" -DestinationPath "${stage.path}"',
      ]);
    }
    if (r.exitCode != 0) {
      throw FormatException('it could not be unpacked: ${r.stderr}'.trim());
    }
    final root = sourceRootIn(stage, exeName);
    if (root == null) throw FormatException('there is no $exeName in what arrived');
    return root;
  }

  /// The folder holding [exe], inside what was unpacked: the stage itself when the
  /// archive was flat (the Windows zip), or the one folder in it (the Linux tarball,
  /// which carries a `wetowl/` folder at its top).
  static Directory? sourceRootIn(Directory stage, String exe) {
    if (File('${stage.path}${Platform.pathSeparator}$exe').existsSync()) return stage;
    final dirs = stage.listSync().whereType<Directory>().toList();
    if (dirs.length == 1 &&
        File('${dirs.single.path}${Platform.pathSeparator}$exe').existsSync()) {
      return dirs.single;
    }
    return null;
  }

  /// The few lines that do the swap once the app is gone.
  ///
  /// Given the app's process id, the unpacked build, the folder to put it in and the
  /// program's name. They wait for the process to end, copy the new build over the
  /// old — over, not instead of: a file the new build no longer ships is left, which
  /// is harmless, where deleting the folder first and then failing to copy would be
  /// no app at all — and start the program again from where it is.
  static String swapScript({
    required String os,
    required int pid,
    required String from,
    required String into,
    required String exe,
  }) {
    if (os == 'windows') {
      return [
        '@echo off',
        'rem Written by WetOwl to bring in a new build of itself. Safe to delete.',
        ':wait',
        'tasklist /FI "PID eq $pid" 2>NUL | find "$pid" >NUL',
        'if not errorlevel 1 (timeout /t 1 /nobreak >NUL & goto wait)',
        'robocopy "$from" "$into" /E /R:10 /W:1 >NUL',
        'if errorlevel 8 exit /b 1',
        'start "" "$into\\$exe"',
        '',
      ].join('\r\n');
    }
    return [
      '#!/bin/sh',
      '# Written by WetOwl to bring in a new build of itself. Safe to delete.',
      'pid=$pid',
      'from=${_sh(from)}',
      'into=${_sh(into)}',
      'exe=${_sh(exe)}',
      'while kill -0 "\$pid" 2>/dev/null; do sleep 0.3; done',
      'cp -a "\$from/." "\$into/" || exit 1',
      'chmod +x "\$into/\$exe" "\$into/wetowl-fetch" 2>/dev/null',
      'cd "\$into" && nohup "./\$exe" >/dev/null 2>&1 &',
      '',
    ].join('\n');
  }

  static String _sh(String s) => "'${s.replaceAll("'", "'\\''")}'";

  /// Close, and come back as the new build.
  Future<void> _applyDesktop() async {
    final os = desktop;
    final from = _staged;
    if (os == null || from == null) return;
    try {
      final into = installDir;
      if (!await canWriteInstallDir(into)) {
        throw FileSystemException(
            'this copy is installed somewhere it cannot write to; '
            'download the build and unpack it over the old one by hand',
            into.path);
      }
      final scripts = from.parent;
      final script = File(
          '${scripts.path}${Platform.pathSeparator}swap${os == 'windows' ? '.cmd' : '.sh'}');
      await script.writeAsString(swapScript(
          os: os, pid: pid, from: from.path, into: into.path, exe: exeName));
      // Detached: not this app's child, so it is still there after this app is not.
      if (os == 'windows') {
        await Process.start('cmd.exe', ['/c', script.path],
            mode: ProcessStartMode.detached);
      } else {
        await Process.start('sh', [script.path], mode: ProcessStartMode.detached);
      }
      // A moment for the shell to be up, then out of its way.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      exit(0);
    } catch (e) {
      trouble = e is FileSystemException ? e.message : '$e';
      state = Updating.failed;
      notifyListeners();
    }
  }

}
