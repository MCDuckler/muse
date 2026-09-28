// wetowl-update: the new build put where the old one was, once the old one has gone.
//
// An app cannot replace its own files while it is running — on Windows because they
// are held open, on Linux because it would be swapped out from under itself — so
// something else has to do it after the window shuts. That something was a few lines
// of shell the app wrote out and left behind: a .cmd, then a .ps1 when the .cmd could
// not do the one thing it had to.
//
// Neither worked on the machine it had to work on, and the second one failed *silently*
// — the window went away, came back, and was the same build as before — which is the
// worst way for an updater to fail, because there is nothing to read afterwards. A
// script written into AppData and started detached is also the shape of thing that
// script policy and antivirus stop without saying so, and then there is nothing to read
// because nothing ever ran.
//
// So it is a program instead. It ships beside the app like wetowl-fetch and
// wetowl-separate do, it is a binary rather than a script, and — the part that matters
// most after three goes at this — it is written in the same language as the app, so it
// can be run and tested on the machine this is developed on rather than reasoned about
// from a distance.
//
// It is run from the *unpacked new build*, not from the installed one, so the program
// doing the replacing is never a file it has to replace.
//
//   wetowl-update --pid 1234 --from <unpacked> --into <installed> --exe wetowl[.exe]
//                 [--say <folder for swap-log.txt and swap-failed.txt>]
import 'dart:io';

/// How long to wait for the app to be gone before going ahead anyway. Past this it is
/// hung rather than busy, and leaving somebody with no new build is worse than
/// replacing what can be replaced under it.
const _waitAtMost = Duration(seconds: 90);

/// What a file that could not be replaced is renamed to, and cleared away next time.
const _aside = '.wetowl-old';

void main(List<String> argv) async {
  final args = <String, String>{};
  for (var i = 0; i + 1 < argv.length; i += 2) {
    if (argv[i].startsWith('--')) args[argv[i].substring(2)] = argv[i + 1];
  }
  final from = args['from'], into = args['into'], exe = args['exe'];
  final pid = int.tryParse(args['pid'] ?? '');
  if (from == null || into == null || exe == null) {
    stderr.writeln('usage: wetowl-update --pid N --from DIR --into DIR --exe NAME');
    exit(2);
  }

  // Where it writes down what it did, for the app to read on the way back up and send
  // home. Told explicitly, because the app has a folder it looks in and guessing at it
  // from here is how a swap ends up leaving its account somewhere nobody reads.
  final reportsIn = args['say'] ?? Directory(from).parent.path;
  final log = File('$reportsIn${Platform.pathSeparator}swap-log.txt');
  final bad = File('$reportsIn${Platform.pathSeparator}swap-failed.txt');
  void say(String what) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    try {
      log.writeAsStringSync(
          '${two(now.hour)}:${two(now.minute)}:${two(now.second)}  $what\n',
          mode: FileMode.append);
    } catch (_) {}
  }

  try {
    if (bad.existsSync()) bad.deleteSync();
  } catch (_) {}
  say('putting $from into $into');

  if (pid != null) {
    final until = DateTime.now().add(_waitAtMost);
    while (DateTime.now().isBefore(until) && _stillThere(pid)) {
      sleep(const Duration(milliseconds: 200));
    }
    say(_stillThere(pid) ? 'it is still running; going ahead' : 'it has gone');
  }
  // A breath for the engine to give its files back after the process ends.
  sleep(const Duration(milliseconds: 300));

  final source = Directory(from);
  if (!source.existsSync()) {
    _giveUp(bad, say, 'there is nothing at $from to put anywhere', into, exe);
    return;
  }

  // Last time's cast-offs, now that nothing holds them. Walked without following
  // links: one of these may itself be a link that leads nowhere, and asking where it
  // leads would end the walk before it reached the rest.
  try {
    for (final f in Directory(into).listSync(recursive: true, followLinks: false)) {
      if (f.path.endsWith(_aside)) {
        try {
          f.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  } catch (_) {}

  var did = 0;
  final stuck = <String>[];
  final root = source.path.replaceAll(RegExp(r'[\\/]+$'), '');
  for (final f in source.listSync(recursive: true)) {
    if (f is! File) continue;
    final rel = f.path.substring(root.length + 1);
    final to = File('$into${Platform.pathSeparator}$rel');
    try {
      to.parent.createSync(recursive: true);
    } catch (_) {}
    try {
      f.copySync(to.path);
      did++;
    } catch (_) {
      // Held open, or not a plain file at all. Either way what is there can still be
      // *renamed* — on Windows as on Linux, an open file can be moved — and the new one
      // then lands in the name it left; the old one goes next time.
      try {
        _moveAside(to.path);
        f.copySync(to.path);
        did++;
        say('moved aside: $rel');
      } catch (e) {
        stuck.add(rel);
        say('could not replace $rel: $e');
      }
    }
  }

  if (did == 0) {
    _giveUp(bad, say, 'nothing was copied out of $from', into, exe);
    return;
  }
  if (stuck.isNotEmpty) {
    try {
      bad.writeAsStringSync(
          'the new build could not replace these files:\n\n${stuck.join('\n')}\n');
    } catch (_) {}
  }
  say('done: $did copied, ${stuck.length} left behind');
  _startAgain(into, exe, say);
}

/// Renames whatever is at [path] out of the way, to the same name plus [_aside].
///
/// Whatever: the thing being replaced is usually a held-open file, but it can be a link
/// or a folder, and each of those is renamed by its own kind in Dart — `File.renameSync`
/// looks at what it was handed first and refuses anything that is not a plain file. A
/// link that leads nowhere is exactly the shape of the Windows case (there, but not
/// openable), so getting this wrong would have shipped the same silent no-op a third
/// time.
void _moveAside(String path) {
  final aside = '$path$_aside';
  switch (FileSystemEntity.typeSync(aside, followLinks: false)) {
    case FileSystemEntityType.notFound:
      break;
    case FileSystemEntityType.directory:
      Directory(aside).deleteSync(recursive: true);
    case FileSystemEntityType.link:
      Link(aside).deleteSync();
    default:
      File(aside).deleteSync();
  }
  switch (FileSystemEntity.typeSync(path, followLinks: false)) {
    case FileSystemEntityType.directory:
      Directory(path).renameSync(aside);
    case FileSystemEntityType.link:
      Link(path).renameSync(aside);
    default:
      File(path).renameSync(aside);
  }
}

/// Whether [pid] is still a process. Asked without disturbing it.
bool _stillThere(int pid) {
  try {
    if (Platform.isWindows) {
      final r = Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH']);
      return '${r.stdout}'.contains('$pid');
    }
    // A signal that does nothing to a process that is already running, and false for
    // one that is not there at all.
    return Process.killPid(pid, ProcessSignal.sigcont);
  } catch (_) {
    return false;
  }
}

void _giveUp(File bad, void Function(String) say, String why, String into, String exe) {
  say(why);
  try {
    bad.writeAsStringSync('$why\n');
  } catch (_) {}
  // Started again regardless: taking somebody's app away is not an improvement on
  // giving them the one they had.
  _startAgain(into, exe, say);
}

void _startAgain(String into, String exe, void Function(String) say) {
  try {
    Process.start('$into${Platform.pathSeparator}$exe', const [],
        workingDirectory: into, mode: ProcessStartMode.detached);
    say('started it again');
  } catch (e) {
    say('could not start it again: $e');
  }
}
