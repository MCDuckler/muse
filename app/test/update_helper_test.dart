// wetowl-update, run for real.
//
// This is the whole point of it being a program rather than a script: the swap can be
// exercised on the machine it is written on. The two before it could not be — a .cmd
// needs Windows, and the .ps1 needed a PowerShell dragged in specially — and both
// shipped broken, the second one failing silently on the one machine that mattered.
@TestOn('linux')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late String helper;

  setUpAll(() async {
    // Built once, the same way the desktop workflow builds the one that ships — so
    // what is exercised here is what is shipped. `dart build cli` rather than
    // `dart compile exe`, because a package in the tree has build hooks and compile
    // refuses those; and into a folder that does not exist yet, which it insists on.
    final out = Directory.systemTemp.createTempSync('wetowl-update-build-');
    addTearDown(() => out.deleteSync(recursive: true));
    final r = await Process.run('dart',
        ['build', 'cli', '--target', 'bin/wetowl_update.dart', '-o', '${out.path}/built']);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    helper = '${out.path}/built/bundle/bin/wetowl_update';
    expect(File(helper).existsSync(), isTrue, reason: 'no helper at $helper');
  });

  setUp(() => root = Directory.systemTemp.createTempSync('wetowl-swap-'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// A pretend build: a program that writes its name when started, and a file under it.
  Directory build(String at, String says) {
    final dir = Directory('${root.path}/$at');
    Directory('${dir.path}/lib').createSync(recursive: true);
    File('${dir.path}/lib/engine.so').writeAsStringSync(says);
    File('${dir.path}/build-stamp.txt').writeAsStringSync(says);
    final exe = File('${dir.path}/wetowl');
    exe.writeAsStringSync('#!/bin/sh\necho "$says" > "${root.path}/started.txt"\n');
    Process.runSync('chmod', ['+x', exe.path]);
    return dir;
  }

  Future<ProcessResult> swap(Directory from, Directory into, {int? pid, String? say}) =>
      Process.run(helper, [
        '--pid', '${pid ?? 999999}',
        '--from', from.path,
        '--into', into.path,
        '--exe', 'wetowl',
        if (say != null) ...['--say', say],
      ]);

  Future<void> startedSaying(String what) async {
    final f = File('${root.path}/started.txt');
    for (var i = 0; i < 60 && !f.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(f.existsSync(), isTrue, reason: 'it never started the app again');
    expect(f.readAsStringSync().trim(), what);
  }

  test('it waits for the app to go, puts the new build in, and starts it', () async {
    final into = build('app', 'old');
    File('${into.path}/leftover.txt').writeAsStringSync('stays');
    final from = build('stage', 'new');
    final app = await Process.start('sleep', ['1.0']);

    final began = DateTime.now();
    final r = await swap(from, into, pid: app.pid);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    expect(DateTime.now().difference(began).inMilliseconds, greaterThan(700),
        reason: 'it copied while the app was still running');

    expect(File('${into.path}/build-stamp.txt').readAsStringSync(), 'new');
    expect(File('${into.path}/lib/engine.so').readAsStringSync(), 'new',
        reason: 'it goes down into the folders');
    expect(File('${into.path}/leftover.txt').readAsStringSync(), 'stays',
        reason: 'copied over, not replaced: a failed copy must not leave no app');
    expect(File('${root.path}/swap-failed.txt').existsSync(), isFalse);
    await startedSaying('new');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a file it cannot write over is moved aside and replaced anyway', () async {
    final into = build('app2', 'old');
    // In the way and not writable through: a link to nowhere, which stands in for the
    // file Windows has open. Either way the copy is refused and the way out is the
    // same — rename what is there, put the new one in the name it left.
    File('${into.path}/lib/engine.so').deleteSync();
    Link('${into.path}/lib/engine.so').createSync('/nowhere/at/all');
    final from = build('stage2', 'new');

    final r = await swap(from, into);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    expect(File('${into.path}/lib/engine.so').readAsStringSync(), 'new');
    expect(Link('${into.path}/lib/engine.so.wetowl-old').existsSync(), isTrue,
        reason: 'the old one waits beside it until something can delete it');
    expect(File('${root.path}/swap-failed.txt').existsSync(), isFalse,
        reason: 'it recovered, so there is nothing to report');
    await startedSaying('new');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('last time\'s cast-offs are cleared away', () async {
    final into = build('app3', 'old');
    File('${into.path}/lib/engine.so.wetowl-old').writeAsStringSync('older');
    final from = build('stage3', 'new');
    await swap(from, into);
    expect(File('${into.path}/lib/engine.so.wetowl-old').existsSync(), isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a swap with nothing to copy says so rather than looking like it worked',
      () async {
    // The failure that started all this: the window goes, comes back, and is the same
    // build, with nothing anywhere saying why.
    final into = build('app4', 'old');
    final r = await Process.run(helper, [
      '--pid', '999999',
      '--from', '${root.path}/no-such-stage',
      '--into', into.path,
      '--exe', 'wetowl',
    ]);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    final said = File('${root.path}/swap-failed.txt');
    expect(said.existsSync(), isTrue, reason: 'it copied nothing and said nothing');
    expect(said.readAsStringSync(), contains('no-such-stage'),
        reason: 'and where it looked');
    expect(File('${into.path}/build-stamp.txt').readAsStringSync(), 'old');
    await startedSaying('old');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('what it truly could not replace is left in writing, and it starts anyway',
      () async {
    final into = build('app5', 'old');
    final from = build('stage5', 'new');
    // A file the new build ships whose folder is a file in the install: nothing to
    // copy into and nothing to rename out of the way.
    Directory('${from.path}/lib/deep').createSync();
    File('${from.path}/lib/deep/x.so').writeAsStringSync('new');
    File('${into.path}/lib/deep').writeAsStringSync('in the way');

    final r = await swap(from, into);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    final said = File('${root.path}/swap-failed.txt');
    expect(said.existsSync(), isTrue);
    expect(said.readAsStringSync(), contains('x.so'));
    expect(File('${into.path}/build-stamp.txt').readAsStringSync(), 'new',
        reason: 'one file it could not place does not stop the rest');
    await startedSaying('new');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('it reports where it is told to, which is where the app looks', () async {
    // The app reads swap-log.txt and swap-failed.txt out of its own updates folder
    // (Updates.sayWhatTheSwapDid). Guessing that folder from in here is how a swap
    // ends up leaving its account somewhere nobody reads — which is how the last two
    // failed without leaving a word.
    final into = build('app7', 'old');
    final from = build('stage7', 'new');
    final elsewhere = Directory('${root.path}/somewhere-else')..createSync();
    await swap(from, into, say: elsewhere.path);
    expect(File('${elsewhere.path}/swap-log.txt').existsSync(), isTrue);
    expect(File('${root.path}/swap-log.txt').existsSync(), isFalse,
        reason: 'not beside the stage as well');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('it writes down what it did, for the app to send on', () async {
    final into = build('app6', 'old');
    final from = build('stage6', 'new');
    await swap(from, into);
    final log = File('${root.path}/swap-log.txt');
    expect(log.existsSync(), isTrue);
    final words = log.readAsStringSync();
    expect(words, contains('putting'));
    expect(words, contains('done:'));
    expect(words, contains('started it again'));
  }, timeout: const Timeout(Duration(seconds: 60)));
}
