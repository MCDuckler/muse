import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Where the log is, or null where there is none.
String? get appLogPath => _file?.path;
File? _file;
IOSink? _sink;
int _written = 0;
final _early = <String>[];

/// At most this much, then the file is rolled over once (wetowl.log.1) — a booth
/// left running for days must not fill a disk.
const _mostBytes = 2 << 20;

/// Every line debugPrint says, and every error Flutter catches, into
/// `<app support>/wetowl.log` — with the time, so a freeze can be placed.
Future<void> startAppLog() async {
  if (kIsWeb || !(Platform.isLinux || Platform.isWindows || Platform.isMacOS)) return;
  final before = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    before(message, wrapWidth: wrapWidth);
    if (message != null) _write(message);
  };
  final onError = FlutterError.onError;
  FlutterError.onError = (details) {
    _write('ERROR ${details.exceptionAsString()}\n${details.stack ?? ''}');
    onError?.call(details);
  };
  try {
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}${Platform.pathSeparator}wetowl.log');
    if (await f.exists() && await f.length() > _mostBytes) {
      try {
        await f.rename('${f.path}.1');
      } catch (_) {}
    }
    _file = f;
    _written = await f.exists() ? await f.length() : 0;
    _sink = f.openWrite(mode: FileMode.append);
    _sink!.writeln('--- ${DateTime.now().toIso8601String()} started');
    for (final line in _early) {
      _sink!.writeln(line);
    }
    _early.clear();
  } catch (_) {
    _file = null;
  }
}

void _write(String message) {
  final line = '${DateTime.now().toIso8601String().substring(11, 23)} $message';
  final sink = _sink;
  if (sink == null) {
    if (_early.length < 500) _early.add(line);
    return;
  }
  _written += line.length + 1;
  sink.writeln(line);
  if (_written > _mostBytes) {
    // Rolled over: this file becomes .1, and a fresh one carries on.
    _written = 0;
    final f = _file!;
    unawaited(() async {
      await sink.flush();
      await sink.close();
      try {
        await f.rename('${f.path}.1');
      } catch (_) {}
      _sink = f.openWrite(mode: FileMode.append);
    }());
  }
}
