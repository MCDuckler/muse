// wetowl-update on a Mac's app bundle, run for real.
//
// A bundle is swapped whole rather than file by file (see _swapBundle in
// bin/wetowl_update.dart), and that is file moves and nothing a Linux box cannot do,
// so it is exercised here as well as on the Mac the release is built on. On a Mac the
// app is opened again with `open`, so the pretend bundles are real enough to open.
@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/updates.dart';

void main() {
  late Directory root;
  late String helper;

  setUpAll(() async {
    final out = Directory.systemTemp.createTempSync('wetowl-update-build-');
    addTearDown(() => out.deleteSync(recursive: true));
    final r = await Process.run('dart',
        ['build', 'cli', '--target', 'bin/wetowl_update.dart', '-o', '${out.path}/built']);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    helper = '${out.path}/built/bundle/bin/wetowl_update';
    expect(File(helper).existsSync(), isTrue, reason: 'no helper at $helper');
  });

  // Resolved: on a Mac the temporary folder is behind a link (/var → /private/var).
  setUp(() => root =
      Directory(Directory.systemTemp.createTempSync('wetowl-bundle-').resolveSymbolicLinksSync()));
  tearDown(() {
    if (root.existsSync()) {
      Process.runSync('chmod', ['-R', 'u+w', root.path]);
      root.deleteSync(recursive: true);
    }
  });

  /// A pretend WetOwl.app: a program that writes what it is when started, a framework
  /// with the links a real one has, and the stamp where a Mac build keeps it.
  Directory bundle(String at, String says) {
    final app = Directory('${root.path}/$at/WetOwl.app');
    final contents = '${app.path}/Contents';
    Directory('$contents/MacOS').createSync(recursive: true);
    Directory('$contents/Resources').createSync(recursive: true);
    File('$contents/Resources/build-stamp.txt').writeAsStringSync(says);
    File('$contents/Info.plist').writeAsStringSync('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>WetOwl</string>
	<key>CFBundleIdentifier</key><string>io.wetowl.swaptest.$says</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
''');
    final fw = Directory('$contents/Frameworks/Mpv.framework/Versions/A')..createSync(recursive: true);
    File('${fw.path}/Mpv').writeAsStringSync(says);
    Link('$contents/Frameworks/Mpv.framework/Versions/Current').createSync('A');
    Link('$contents/Frameworks/Mpv.framework/Mpv').createSync('Versions/Current/Mpv');
    File('$contents/Resources/only-in-$says.txt').writeAsStringSync(says);
    final exe = File('$contents/MacOS/WetOwl');
    exe.writeAsStringSync('#!/bin/sh\necho "$says" > "${root.path}/started.txt"\n');
    Process.runSync('chmod', ['+x', exe.path]);
    return app;
  }

  Future<ProcessResult> swap(Directory from, Directory into, {int? pid}) => Process.run(helper, [
        '--pid', '${pid ?? 999999}',
        '--from', from.path,
        '--into', into.path,
        '--exe', 'WetOwl',
        '--say', root.path,
      ]);

  Future<void> startedSaying(String what) async {
    final f = File('${root.path}/started.txt');
    for (var i = 0; i < 200 && !f.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(f.existsSync(), isTrue, reason: 'it never opened the app again');
    expect(f.readAsStringSync().trim(), what);
  }

  String log() {
    final f = File('${root.path}/swap-log.txt');
    return f.existsSync() ? f.readAsStringSync() : '(no log)';
  }

  test('the bundle is replaced whole, the old one goes, and the new one is opened', () async {
    final into = bundle('Applications', 'old');
    final from = bundle('stage', 'new');
    final app = await Process.start('sleep', ['0.8']);

    final r = await swap(from, into, pid: app.pid);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');

    final contents = '${into.path}/Contents';
    expect(File('$contents/Resources/build-stamp.txt').readAsStringSync(), 'new', reason: log());
    expect(File('$contents/Frameworks/Mpv.framework/Mpv').readAsStringSync(), 'new',
        reason: 'the links inside a framework came through as links');
    expect(FileSystemEntity.isLinkSync('$contents/Frameworks/Mpv.framework/Versions/Current'),
        isTrue);
    expect(File('$contents/Resources/only-in-old.txt').existsSync(), isFalse,
        reason: 'whole, not over the top: nothing of the old bundle is left in it');
    expect(Directory('${into.path}.wetowl-old').existsSync(), isFalse, reason: log());
    expect(from.existsSync(), isFalse, reason: 'moved, not copied');
    await startedSaying('new');
    expect(File('${root.path}/swap-failed.txt').existsSync(), isFalse);
  });

  test('where the old one cannot be moved, it is left as it was and opened again', () async {
    final into = bundle('Applications', 'old');
    final from = bundle('stage', 'new');
    // The folder the app is in is not ours to change: /Applications for somebody who
    // is not an administrator.
    Process.runSync('chmod', ['a-w', into.parent.path]);

    final r = await swap(from, into);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    expect(File('${into.path}/Contents/Resources/build-stamp.txt').readAsStringSync(), 'old');
    expect(File('${root.path}/swap-failed.txt').readAsStringSync(),
        contains('could not move the installed app aside'));
    await startedSaying('old');
  });

  test('a stage with nothing in it changes nothing, and says so', () async {
    final into = bundle('Applications', 'old');
    final r = await swap(Directory('${root.path}/stage/WetOwl.app'), into);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    expect(File('${into.path}/Contents/Resources/build-stamp.txt').readAsStringSync(), 'old');
    expect(File('${root.path}/swap-failed.txt').existsSync(), isTrue);
    await startedSaying('old');
  });

  test('last time\'s leftover is cleared first', () async {
    final into = bundle('Applications', 'old');
    Directory('${into.path}.wetowl-old/Contents').createSync(recursive: true);
    final from = bundle('stage', 'new');
    final r = await swap(from, into);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    expect(File('${into.path}/Contents/Resources/build-stamp.txt').readAsStringSync(), 'new',
        reason: log());
    expect(Directory('${into.path}.wetowl-old').existsSync(), isFalse);
    await startedSaying('new');
  });

  test('the app finds the bundle in what it unpacked', () {
    final stage = Directory('${root.path}/stage')..createSync();
    bundle('stage', 'new');
    expect(Updates.sourceRootIn(stage, 'WetOwl')?.path, '${stage.path}/WetOwl.app');
  });
}
