// A desktop build replacing itself.
//
// The app cannot overwrite its own files while it runs, so the swap is a few lines of
// shell it leaves behind. Those lines are the whole feature: if they wait wrong, copy
// wrong or start the wrong thing, the result is a folder with no app in it. So they
// are run here, for real, against a pretend install.
@TestOn('linux')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/updates.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wetowl-update-');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// A pretend build: a program that writes its name to a file when started.
  Future<Directory> build(String at, String says) async {
    final dir = Directory('${root.path}/$at');
    await Directory('${dir.path}/lib').create(recursive: true);
    await File('${dir.path}/lib/libflutter.so').writeAsString(says);
    await File('${dir.path}/build-stamp.txt').writeAsString(says);
    final exe = File('${dir.path}/wetowl');
    await exe.writeAsString('#!/bin/sh\necho "$says" > "${root.path}/started.txt"\n');
    await Process.run('chmod', ['+x', exe.path]);
    return dir;
  }

  test('the build is found inside what was unpacked, flat or in a folder', () async {
    final flat = await build('flat', '1');
    expect(Updates.sourceRootIn(flat, 'wetowl')?.path, flat.path);

    final wrapped = Directory('${root.path}/wrapped');
    await wrapped.create();
    final inside = await build('wrapped/wetowl', '2');
    expect(Updates.sourceRootIn(wrapped, 'wetowl')?.path, inside.path,
        reason: 'the Linux tarball carries a wetowl/ folder at its top');

    final empty = await Directory('${root.path}/empty').create();
    expect(Updates.sourceRootIn(empty, 'wetowl'), isNull);
  });

  test('a tarball is unpacked and the build found in it', () async {
    final made = await build('src/wetowl', '3');
    final tar = File('${root.path}/wetowl-linux.tar.gz');
    final r = await Process.run(
        'tar', ['-C', made.parent.path, '-czf', tar.path, 'wetowl']);
    expect(r.exitCode, 0, reason: '${r.stderr}');

    final from = await Updates.stageDesktop(tar, Directory('${root.path}/stage'));
    expect(File('${from.path}/wetowl').existsSync(), isTrue);
    expect(File('${from.path}/lib/libflutter.so').readAsStringSync(), '3');
  });

  test('the swap waits for the app to go, copies the new build over, starts it',
      () async {
    final installed = await build('app', 'old');
    await File('${installed.path}/leftover.txt').writeAsString('stays');
    final fresh = await build('stage/wetowl', 'new');

    // The "running app": something that is alive for a moment and then is not.
    final app = await Process.start('sleep', ['0.8']);
    final script = File('${root.path}/swap.sh');
    await script.writeAsString(Updates.swapScript(
        os: 'linux',
        pid: app.pid,
        from: fresh.path,
        into: installed.path,
        exe: 'wetowl'));

    final began = DateTime.now();
    final swap = await Process.run('sh', [script.path]);
    expect(swap.exitCode, 0, reason: '${swap.stderr}');
    expect(DateTime.now().difference(began).inMilliseconds, greaterThan(500),
        reason: 'it waited for the app to close rather than copying under it');

    expect(File('${installed.path}/build-stamp.txt').readAsStringSync(), 'new');
    expect(File('${installed.path}/lib/libflutter.so').readAsStringSync(), 'new');
    expect(File('${installed.path}/leftover.txt').readAsStringSync(), 'stays',
        reason: 'copied over, not replaced: a failed copy must not leave no app');

    // And the new one was started, from its own folder.
    final started = File('${root.path}/started.txt');
    for (var i = 0; i < 50 && !started.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    expect(started.existsSync(), isTrue, reason: 'the new build was started');
    expect(started.readAsStringSync().trim(), 'new');
  });

  test('a program still running from the old folder does not stop the swap', () async {
    final installed = await build('app2', 'old');
    // The background helper: a copy of `sleep` running from the install folder, which
    // is a busy text file that cannot be copied over.
    final busy = File('${installed.path}/wetowl-fetch');
    await File('/bin/sleep').copy(busy.path);
    await Process.run('chmod', ['+x', busy.path]);
    final helper = await Process.start(busy.path, ['5']);
    addTearDown(helper.kill);
    final fresh = await build('stage2/wetowl', 'new');
    await File('${fresh.path}/wetowl-fetch').writeAsString('#!/bin/sh\necho new\n');

    final app = await Process.start('sleep', ['0.1']);
    final script = File('${root.path}/swap2.sh');
    await script.writeAsString(Updates.swapScript(
        os: 'linux', pid: app.pid, from: fresh.path, into: installed.path, exe: 'wetowl'));
    final swap = await Process.run('sh', [script.path]);
    expect(swap.exitCode, 0, reason: '${swap.stderr}');
    expect(busy.readAsStringSync(), contains('echo new'),
        reason: 'renamed into place under the running one');
    expect(File('${installed.path}/build-stamp.txt').readAsStringSync(), 'new');
  });

  test('the Windows script says what it will do, in lines PowerShell can read', () {
    final s = Updates.swapScript(
        os: 'windows',
        pid: 4242,
        from: r'C:\Users\me\AppData\stage',
        into: r'C:\Users\me\WetOwl',
        exe: 'wetowl.exe',
        beside: r'C:\Users\me\AppData');

    expect(s, contains(r"$app  = 4242"), reason: 'it waits for that process');
    expect(s, contains("Get-Process -Id \$app"));
    expect(s, contains(r"$from = 'C:\Users\me\AppData\stage'"));
    expect(s, contains(r"$into = 'C:\Users\me\WetOwl'"));
    // The whole point of the rewrite: a file something still has open is renamed out
    // of the way and the new one put in its place, which Windows allows and writing
    // over it does not.
    expect(s, contains('.wetowl-old'));
    expect(s, contains('Move-Item'));
    expect(s, contains('Start-Process -FilePath \$run -WorkingDirectory \$into'),
        reason: 'started from its own folder, as the Linux branch does');
    expect(s, contains(Updates.swapTroubleFile),
        reason: 'a swap that could not finish leaves word for the next run');
    expect(s.split('\n').every((l) => l.isEmpty || l.endsWith('\r')), isTrue,
        reason: 'the shell wants its line endings');
    // A path with a quote in it is a path, not the end of a string.
    final odd = Updates.swapScript(
        os: 'windows',
        pid: 1,
        from: r"C:\O'Brien\stage",
        into: r"C:\O'Brien\WetOwl",
        exe: 'wetowl.exe');
    expect(odd, contains(r"$from = 'C:\O''Brien\stage'"));
  });

  // Windows is the one this could not be run on, so it is run here. PowerShell reads
  // the same script on Linux — the paths come back with the other slash and every
  // command in it is the same one — so the wait, the walk, the copy, the recovery and
  // the restart are all exercised for real, and only the file locking that makes the
  // recovery necessary is Windows'.
  group('the Windows script, run', () {
    late String shell;

    setUpAll(() {
      shell = Platform.environment['WETOWL_PWSH'] ?? 'pwsh';
    });

    bool haveShell() {
      try {
        return Process.runSync(shell, ['-NoProfile', '-Command', 'exit 0']).exitCode ==
            0;
      } catch (_) {
        return false;
      }
    }

    test('it waits, replaces the build, clears last time\'s cast-offs and starts it',
        () async {
      if (!haveShell()) {
        // Said out loud rather than passed quietly: a test that did not run is not
        // a test that went well. Point WETOWL_PWSH at one to run these.
        markTestSkipped('no PowerShell here to read the script');
        return;
      }
      final installed = await build('win', 'old');
      await File('${installed.path}/leftover.txt').writeAsString('stays');
      // What the update before this one could not delete at the time.
      await File('${installed.path}/lib/libflutter.so.wetowl-old').writeAsString('older');
      final fresh = await build('winstage/wetowl', 'new');

      final app = await Process.start('sleep', ['0.8']);
      final script = File('${root.path}/swap.ps1');
      await script.writeAsString(Updates.swapScript(
          os: 'windows',
          pid: app.pid,
          from: fresh.path,
          into: installed.path,
          exe: 'wetowl',
          beside: root.path));

      final began = DateTime.now();
      final r = await Process.run(
          shell, ['-NoProfile', '-NonInteractive', '-File', script.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      expect(DateTime.now().difference(began).inMilliseconds, greaterThan(500),
          reason: 'it waited for the app to close rather than copying under it');

      expect(File('${installed.path}/build-stamp.txt').readAsStringSync(), 'new');
      expect(File('${installed.path}/lib/libflutter.so').readAsStringSync(), 'new',
          reason: 'it goes down into the folders too');
      expect(File('${installed.path}/leftover.txt').readAsStringSync(), 'stays',
          reason: 'copied over, not replaced');
      expect(File('${installed.path}/lib/libflutter.so.wetowl-old').existsSync(), isFalse,
          reason: 'the last swap\'s leftovers go once nothing holds them');
      expect(File('${root.path}/${Updates.swapTroubleFile}').existsSync(), isFalse,
          reason: 'nothing to complain about');

      final started = File('${root.path}/started.txt');
      for (var i = 0; i < 50 && !started.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      expect(started.readAsStringSync().trim(), 'new');
    });

    test('a file it cannot write over is moved aside and replaced anyway', () async {
      if (!haveShell()) {
        // Said out loud rather than passed quietly: a test that did not run is not
        // a test that went well. Point WETOWL_PWSH at one to run these.
        markTestSkipped('no PowerShell here to read the script');
        return;
      }
      final installed = await build('win2', 'old');
      // Something in the way that the copy is refused — on Windows a file the fetcher
      // still has open, here a link to nowhere, which PowerShell will not write
      // through. Either way the recovery is the same one, and it is the recovery being
      // tested: rename what is in the way, and put the new one where it was.
      await File('${installed.path}/lib/libflutter.so').delete();
      await Link('${installed.path}/lib/libflutter.so').create('/nowhere/at/all');
      final fresh = await build('winstage2/wetowl', 'new');

      final app = await Process.start('sleep', ['0.1']);
      final script = File('${root.path}/swap2.ps1');
      await script.writeAsString(Updates.swapScript(
          os: 'windows',
          pid: app.pid,
          from: fresh.path,
          into: installed.path,
          exe: 'wetowl',
          beside: root.path));
      final r = await Process.run(
          shell, ['-NoProfile', '-NonInteractive', '-File', script.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');

      expect(File('${installed.path}/lib/libflutter.so').readAsStringSync(), 'new',
          reason: 'the new file landed in the name the old one had');
      expect(Link('${installed.path}/lib/libflutter.so.wetowl-old').existsSync(), isTrue,
          reason: 'the old one is beside it until something can delete it');
      expect(File('${root.path}/${Updates.swapTroubleFile}').existsSync(), isFalse,
          reason: 'it recovered, so there is nothing to report');
      expect(File('${installed.path}/build-stamp.txt').readAsStringSync(), 'new',
          reason: 'one file in the way does not stop the rest');
    });

    test('what it truly could not replace is left in writing, and it starts anyway',
        () async {
      if (!haveShell()) {
        // Said out loud rather than passed quietly: a test that did not run is not
        // a test that went well. Point WETOWL_PWSH at one to run these.
        markTestSkipped('no PowerShell here to read the script');
        return;
      }
      final installed = await build('win3', 'old');
      final fresh = await build('winstage3/wetowl', 'new');
      // A file the new build ships that cannot be put anywhere: its folder is a file
      // in the install, so there is nothing to copy into and nothing to rename out of
      // the way either.
      await Directory('${fresh.path}/lib/deep').create();
      await File('${fresh.path}/lib/deep/x.so').writeAsString('new');
      await File('${installed.path}/lib/deep').writeAsString('in the way');

      final app = await Process.start('sleep', ['0.1']);
      final script = File('${root.path}/swap3.ps1');
      await script.writeAsString(Updates.swapScript(
          os: 'windows',
          pid: app.pid,
          from: fresh.path,
          into: installed.path,
          exe: 'wetowl',
          beside: root.path));
      final r = await Process.run(
          shell, ['-NoProfile', '-NonInteractive', '-File', script.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');

      final said = File('${root.path}/${Updates.swapTroubleFile}');
      expect(said.existsSync(), isTrue,
          reason: 'the next run of the app is the only thing left to say it to');
      expect(said.readAsStringSync(), contains('x.so'));
      expect(File('${installed.path}/build-stamp.txt').readAsStringSync(), 'new',
          reason: 'one file it could not place does not stop the rest');
      final started = File('${root.path}/started.txt');
      for (var i = 0; i < 50 && !started.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      expect(started.existsSync(), isTrue,
          reason: 'a swap that went wrong still gives the person their app back');
    });
  });

  test('a folder that cannot be written to is said to be one', () async {
    final locked = await Directory('${root.path}/locked').create();
    await Process.run('chmod', ['555', locked.path]);
    addTearDown(() => Process.run('chmod', ['755', locked.path]));
    // Root can write anywhere; the check is only meaningful for anybody else.
    final asRoot = (await Process.run('id', ['-u'])).stdout.toString().trim() == '0';
    expect(await Updates.canWriteInstallDir(locked), asRoot);
    expect(await Updates.canWriteInstallDir(root), isTrue);
  });
}
