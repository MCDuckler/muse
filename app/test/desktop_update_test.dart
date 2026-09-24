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

  test('the Windows script waits, copies and starts the same way', () {
    final s = Updates.swapScript(
        os: 'windows',
        pid: 4242,
        from: r'C:\Users\me\AppData\stage',
        into: r'C:\Users\me\WetOwl',
        exe: 'wetowl.exe');
    expect(s, contains('PID eq 4242'));
    expect(s, contains('goto wait'), reason: 'it waits for the process to end');
    expect(s, contains(r'robocopy "C:\Users\me\AppData\stage" "C:\Users\me\WetOwl" /E'));
    expect(s, contains(r'start "" "C:\Users\me\WetOwl\wetowl.exe"'));
    expect(s.split('\n').every((l) => l.isEmpty || l.endsWith('\r')), isTrue,
        reason: 'cmd wants its line endings');
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
