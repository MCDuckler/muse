import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../api/connection.dart';
import 'playback_log.dart';

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
    String? left;
    if (os != null) {
      if (!Release.knows(running)) running = await stampBeside() ?? running;
      // A swap that could not replace everything leaves a note in the folder it ran
      // from, because by then there is no app left to tell. This is the app that came
      // back: it is the one that can say it.
      left = await swapTrouble();
      await sayWhatTheSwapDid();
      release = await publishedDesktop(baseUrl, os) ?? release;
    } else {
      release = await published(baseUrl) ?? release;
    }
    if (left != null) {
      trouble = left;
      state = Updating.failed;
    } else {
      state = available ? Updating.ready : Updating.idle;
    }
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
      final dir = await updatesDir();
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
        _staged = await stageDesktop(
            into, Directory('${dir.path}${Platform.pathSeparator}stage'));
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
    String? went;
    try {
      final r = await Process.run(
          'tar', [zip ? '-xf' : '-xzf', archive.path, '-C', stage.path]);
      if (r.exitCode != 0) went = '${r.stderr}'.trim();
    } on ProcessException catch (e) {
      // Windows before 1803 has no tar at all, and then this throws rather than
      // answering — which is not a bad download, it is a machine missing a program,
      // and the machine has another one. Caught, or the fallback below is never
      // reached on the very machines it is for.
      went = e.message;
    }
    if (went != null && zip && Platform.isWindows) {
      try {
        final r = await Process.run(windowsShell, [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          'Expand-Archive -Force -LiteralPath "${archive.path}" -DestinationPath "${stage.path}"',
        ]);
        went = r.exitCode == 0 ? null : '${r.stderr}'.trim();
      } on ProcessException catch (e) {
        went = e.message;
      }
    }
    if (went != null) {
      throw FormatException('it could not be unpacked: $went'.trim());
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

  /// The name the report of a swap that could not finish is left under.
  static const swapTroubleFile = 'swap-failed.txt';

  /// The program that puts the new build in, as it is named beside the exe. Built by
  /// .github/workflows/desktop.yml from bin/wetowl_update.dart.
  static String get updaterName =>
      Platform.isWindows ? 'wetowl-update.exe' : 'wetowl-update';

  /// The few lines that do the swap once the app is gone.
  ///
  /// Given the app's process id, the unpacked build, the folder to put it in and the
  /// program's name. They wait for the process to end, copy the new build over the
  /// old — over, not instead of: a file the new build no longer ships is left, which
  /// is harmless, where deleting the folder first and then failing to copy would be
  /// no app at all — and start the program again from where it is.
  ///
  /// [beside] is where the script itself lives, and where it leaves a word about what
  /// happened; on Windows it is also where a failed swap leaves [swapTroubleFile], for
  /// the next run of the app to read and say out loud.
  static String swapScript({
    required String os,
    required int pid,
    required String from,
    required String into,
    required String exe,
    String? beside,
  }) {
    if (os == 'windows') return _windowsSwap(pid, from, into, exe, beside ?? into);
    return [
      '#!/bin/sh',
      '# Written by WetOwl to bring in a new build of itself. Safe to delete.',
      'pid=$pid',
      'from=${_sh(from)}',
      'into=${_sh(into)}',
      'exe=${_sh(exe)}',
      'while kill -0 "\$pid" 2>/dev/null; do sleep 0.3; done',
      // File by file, each copied beside itself and renamed into place: a program still
      // running from the old file (the background helper) keeps the old one open and the
      // new one lands anyway. Copied straight over, it was "text file busy", and the old
      // helper stayed on the disk and in the pool.
      '(cd "\$from" && find . -type d) | while read -r d; do mkdir -p "\$into/\$d"; done',
      '(cd "\$from" && find . ! -type d) | while read -r f; do '
          'cp -a "\$from/\$f" "\$into/\$f.new" && mv -f "\$into/\$f.new" "\$into/\$f" || exit 1; done '
          '|| exit 1',
      'chmod +x "\$into/\$exe" "\$into/wetowl-fetch" 2>/dev/null',
      'cd "\$into" && nohup "./\$exe" >/dev/null 2>&1 &',
      '',
    ].join('\n');
  }

  static String _sh(String s) => "'${s.replaceAll("'", "'\\''")}'";

  /// The same job in PowerShell, because on Windows it is a different job.
  ///
  /// The old shape was a .cmd around robocopy, and robocopy cannot do the one thing
  /// this needs. Windows will not let a file that something has open be written to —
  /// and something usually does: the windowless fetcher runs from this very folder,
  /// the separator may still be finishing a record, and a DLL the app mapped is not
  /// always given back the instant the window shuts. Robocopy meets that with thirty
  /// retries and then gives up, which is half a minute of waiting followed by a
  /// half-written install and no app started.
  ///
  /// What Windows does allow is renaming a file that is open — the loader keeps the
  /// handle, the name is free — so that is what this does: copy over it, and when
  /// that is refused, move the old one aside and copy the new one into the name it
  /// left. The old one goes at the start of the next update, when nothing holds it.
  /// It is the same trick as the Linux branch's copy-and-rename, told the way this
  /// system tells it.
  ///
  /// Whatever happens, it starts the app again. A swap that went wrong and left the
  /// person looking at a closed window is worse than one that went wrong and said so.
  static String _windowsSwap(
      int pid, String from, String into, String exe, String beside) {
    String q(String s) => "'${s.replaceAll("'", "''")}'";
    return [
      '# Written by WetOwl to bring in a new build of itself. Safe to delete.',
      '\$app  = $pid',
      '\$from = ${q(from)}',
      '\$into = ${q(into)}',
      '\$exe  = ${q(exe)}',
      '\$log  = Join-Path ${q(beside)} \'swap-log.txt\'',
      '\$bad  = Join-Path ${q(beside)} \'$swapTroubleFile\'',
      'function Say(\$m) {',
      '  try { Add-Content -LiteralPath \$log -Value ((Get-Date -Format \'HH:mm:ss\') + \'  \' + \$m) } catch {}',
      '}',
      'try { Remove-Item -LiteralPath \$bad -Force -ErrorAction SilentlyContinue } catch {}',
      'Say ("waiting for " + \$app)',
      '# Gone, or gone on too long: two minutes is far past anything but a hung app,',
      '# and going ahead is better than never coming back.',
      '\$waited = 0',
      'while (\$waited -lt 120000) {',
      '  if (-not (Get-Process -Id \$app -ErrorAction SilentlyContinue)) { break }',
      '  Start-Sleep -Milliseconds 250',
      '  \$waited += 250',
      '}',
      'Start-Sleep -Milliseconds 400',
      '# Last update\'s cast-offs, now that nothing has them open.',
      'try {',
      '  Get-ChildItem -LiteralPath \$into -Recurse -Force -Filter \'*.wetowl-old\' -ErrorAction SilentlyContinue |',
      '    ForEach-Object { try { Remove-Item -LiteralPath \$_.FullName -Force } catch {} }',
      '} catch {}',
      '\$stuck = @()',
      '\$did = 0',
      '# As the system spells it, with no separator on the end: what is left of each',
      '# name once this is cut off the front is where it goes in the install.',
      '\$root = \$from',
      '# -ErrorAction Stop, or this does not throw and the catch never runs.',
      '#',
      '# Resolve-Path writes an error and returns *nothing* when it cannot resolve a',
      '# path, so .Path was \$null, the catch was never entered, \$root was left null,',
      '# and Get-ChildItem over a null path found no files — whereupon the script',
      '# reported itself done, started the app again, and the person watched their',
      '# window go away and come back as the same build it had been. A silent no-op',
      '# that looked exactly like a success. Guarded twice now: the error is caught,',
      '# and nothing is allowed to leave \$root empty.',
      'try {',
      '  \$found = (Resolve-Path -LiteralPath \$from -ErrorAction Stop).Path',
      '  if (\$found) { \$root = \$found }',
      '} catch { Say ("could not resolve " + \$from + ": " + \$_.Exception.Message) }',
      'if (-not \$root) { \$root = \$from }',
      '\$root = ([string]\$root).TrimEnd(\'\\\').TrimEnd(\'/\')',
      'foreach (\$f in Get-ChildItem -LiteralPath \$root -Recurse -File -Force) {',
      '  \$rel = \$f.FullName.Substring(\$root.Length + 1)',
      '  \$dst = Join-Path \$into \$rel',
      '  \$dir = Split-Path -Parent \$dst',
      '  if (-not (Test-Path -LiteralPath \$dir)) {',
      '    try { New-Item -ItemType Directory -Path \$dir -Force | Out-Null } catch {}',
      '  }',
      '  try {',
      '    Copy-Item -LiteralPath \$f.FullName -Destination \$dst -Force -ErrorAction Stop',
      '    \$did++',
      '  } catch {',
      '    try {',
      '      \$aside = \$dst + \'.wetowl-old\'',
      '      Remove-Item -LiteralPath \$aside -Force -ErrorAction SilentlyContinue',
      '      Move-Item -LiteralPath \$dst -Destination \$aside -Force -ErrorAction Stop',
      '      Copy-Item -LiteralPath \$f.FullName -Destination \$dst -Force -ErrorAction Stop',
      '      \$did++',
      '      Say ("moved aside: " + \$rel)',
      '    } catch {',
      '      \$stuck += \$rel',
      '      Say ("could not replace " + \$rel + ": " + \$_.Exception.Message)',
      '    }',
      '  }',
      '}',
      '# Nothing copied at all is a failure, and it is the one that used to look like a',
      '# success: the app went away, came back, and was the same build as before, with',
      '# nothing anywhere saying why. If the walk found no files the place it looked in',
      '# is what to say.',
      'if (\$did -eq 0) {',
      '  try {',
      '    Set-Content -LiteralPath \$bad -Value @(',
      '      \'the new build was never copied: nothing was found to copy.\',',
      '      (\'looked in: \' + \$root),',
      '      (\'that folder exists: \' + (Test-Path -LiteralPath \$root)),',
      '      (\'into: \' + \$into))',
      '  } catch {}',
      '} elseif (\$stuck.Count -gt 0) {',
      '  try {',
      '    Set-Content -LiteralPath \$bad -Value ((\'the new build could not replace these files:\', \'\') + \$stuck)',
      '  } catch {}',
      '}',
      'Say ("done, " + \$did + " copied, " + \$stuck.Count + " left behind")',
      '\$run = Join-Path \$into \$exe',
      'try { Start-Process -FilePath \$run -WorkingDirectory \$into } catch { Say ("could not start: " + \$_.Exception.Message) }',
      '',
    ].join('\r\n');
  }

  /// Where the download, the swap script and the swap's own word about itself live.
  static Future<Directory> updatesDir() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/updates');

  /// Windows PowerShell, by its full name.
  ///
  /// It is on the path on every Windows this app runs on, but the path is somebody
  /// else's to change and a swap that cannot start is an app that does not come back,
  /// so it is asked for where Windows keeps it and only looked up by name if it is
  /// somehow not there.
  static String get windowsShell {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    const under = r'\System32\WindowsPowerShell\v1.0\powershell.exe';
    final full = '$root$under';
    return File(full).existsSync() ? full : 'powershell.exe';
  }

  /// What the last swap could not do, if it could not do something.
  ///
  /// Read once and then forgotten: the point is to say it to the person who is sitting
  /// in front of a build that is half the one they asked for, not to keep saying it.
  static Future<String?> swapTrouble() async {
    try {
      final f = File('${(await updatesDir()).path}'
          '${Platform.pathSeparator}$swapTroubleFile');
      if (!await f.exists()) return null;
      final said = (await f.readAsString()).trim();
      try {
        await f.delete();
      } catch (_) {}
      return said.isEmpty ? null : said;
    } catch (_) {
      return null;
    }
  }

  /// What the swap wrote down about itself last time, into the log that comes back
  /// here — because the one machine this has to work on is not one anybody here can
  /// stand in front of.
  ///
  /// An update that quietly does nothing and starts the old build again leaves no
  /// mark anywhere: the window goes, the window comes back, and it is the same
  /// version. The script says what it did at every step; this is how any of that
  /// reaches the person who can read it. Read once and then deleted, so a machine
  /// where updating works says nothing at all.
  static Future<void> sayWhatTheSwapDid() async {
    try {
      final f = File('${(await updatesDir()).path}'
          '${Platform.pathSeparator}swap-log.txt');
      if (!await f.exists()) return;
      final lines = (await f.readAsString()).trim();
      try {
        await f.delete();
      } catch (_) {}
      if (lines.isEmpty) return;
      for (final l in lines.split('\n').take(24)) {
        PlaybackLog.note('SWAP ${l.trim()}');
      }
    } catch (_) {}
  }

  /// Stops the windowless helper before the files are swapped (set by the pool).
  static Future<void> Function()? stopHelperForUpdate;

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
      // The background helper runs from this folder too: told to stop first, so its
      // own file can be replaced, and started again as the new build by the new app.
      await stopHelperForUpdate?.call();
      // Beside the download rather than inside the unpacked build: the next update
      // empties this folder but deletes the stage outright, and what the swap has to
      // say about itself has to outlive the swap.
      final scripts = await updatesDir();
      // The swap is a program now, and it ships in the build being put in:
      // wetowl-update, beside the exe in the folder just unpacked. Started from
      // *there* rather than from the install, so the thing doing the replacing is
      // never one of the files it has to replace.
      //
      // It follows two scripts the app wrote out and left behind, a .cmd and then a
      // .ps1, neither of which worked on Windows — the second failing *silently*: the
      // window went, came back, and was the same build, with nothing anywhere saying
      // why. A script written into AppData and started detached is also the shape of
      // thing script policy and antivirus stop without a word, and then there is
      // nothing to read because nothing ever ran. A binary beside the exe is neither.
      // And the part that decided it after three goes: a program in the same language
      // as the app can be run, and gone wrong, on the machine it is written on —
      // test/update_helper_test.dart does the whole swap for real.
      final helper = File('${from.path}${Platform.pathSeparator}$updaterName');
      final tellIt = [
        '--pid', '$pid',
        '--from', from.path,
        '--into', into.path,
        '--exe', exeName,
        '--say', scripts.path,
      ];
      final byHelper = await helper.exists();
      if (byHelper) {
        // A tarball keeps the bit; a zip has none to keep.
        if (os != 'windows') {
          try {
            await Process.run('chmod', ['+x', helper.path]);
          } catch (_) {}
        }
        // Detached: not this app's child, so it is still there after this app is not.
        await Process.start(helper.path, tellIt, mode: ProcessStartMode.detached);
      } else {
        // An older build being updated *from* has no helper in what it unpacked only
        // if the new build does not ship one; kept so that a build from before this
        // still has a way through.
        final script = File(
            '${scripts.path}${Platform.pathSeparator}swap${os == 'windows' ? '.ps1' : '.sh'}');
        await script.writeAsString(swapScript(
            os: os,
            pid: pid,
            from: from.path,
            into: into.path,
            exe: exeName,
            beside: scripts.path));
        if (os == 'windows') {
          await Process.start(
              windowsShell,
              [
                '-NoProfile',
                '-NonInteractive',
                '-ExecutionPolicy',
                'Bypass',
                '-WindowStyle',
                'Hidden',
                '-File',
                script.path,
              ],
              mode: ProcessStartMode.detached);
        } else {
          await Process.start('sh', [script.path], mode: ProcessStartMode.detached);
        }
      }
      // Said before going: if the log has this and nothing after it, the swap was
      // started and never wrote a line, which is a different fault from one that ran
      // and could not copy.
      PlaybackLog.note('SWAP starting $os swap by ${byHelper ? 'the helper' : 'a script'}: '
          '${from.path} -> ${into.path}');
      await PlaybackLog.flushNow();
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
