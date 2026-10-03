/// HID on Linux: the kernel's hidraw nodes, read straight.
///
/// `/sys/class/hidraw/hidrawN/device/uevent` says what each node is (HID_ID has the
/// bus, vendor and product; HID_NAME the name). The node is opened non-blocking
/// through libc and read in an isolate that polls it, so closing is a flag the
/// reader sees within a tick rather than a thread stuck in read(2) until the next
/// report. Writing goes through a second descriptor on the main isolate.
///
/// Permission: the nodes are root's unless a udev rule says otherwise. See
/// deploy/udev/99-wetowl-dj.rules; an EACCES here is reported as exactly that.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'hid_transport.dart';
import 'layout.dart';
import 'transport.dart';

class HidrawTransport extends ControllerTransport {
  HidrawTransport(this.layouts, {this.sysRoot = '/sys/class/hidraw', this.devRoot = '/dev'});
  final List<ControllerLayout> layouts;

  /// Where the nodes are described and where they are opened; the real places unless
  /// a test puts a pretend tree somewhere.
  final String sysRoot, devRoot;

  @override
  Protocol get protocol => Protocol.hid;

  @override
  bool get available => Directory(sysRoot).existsSync();

  @override
  String? get unavailableWhy => available ? null : 'No hidraw here: the kernel has no HID support built in.';

  StreamController<void>? _changes;
  StreamSubscription<FileSystemEvent>? _watch;

  /// /dev appearing and disappearing: a hidraw node is one of its files.
  @override
  Stream<void> get changes {
    _changes ??= StreamController<void>.broadcast(onListen: () {
      try {
        _watch = Directory(devRoot).watch(events: FileSystemEvent.create | FileSystemEvent.delete).listen((e) {
          if (e.path.contains('/hidraw')) _changes?.add(null);
        });
      } catch (_) {
        // No inotify on /dev: the manager's own rescans find it.
      }
    }, onCancel: () => _watch?.cancel());
    return _changes!.stream;
  }

  @override
  Future<List<FoundDevice>> scan() async {
    final out = <FoundDevice>[];
    final root = Directory(sysRoot);
    if (!root.existsSync()) return out;
    for (final node in root.listSync()) {
      final name = node.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final uevent = File('${node.path}/device/uevent');
      if (!uevent.existsSync()) continue;
      int? vid, pid;
      String? hidName;
      try {
        for (final line in uevent.readAsLinesSync()) {
          if (line.startsWith('HID_ID=')) {
            // HID_ID=0003:000006F8:0000B101
            final parts = line.substring(7).split(':');
            if (parts.length == 3) {
              vid = int.tryParse(parts[1], radix: 16);
              pid = int.tryParse(parts[2], radix: 16);
            }
          } else if (line.startsWith('HID_NAME=')) {
            hidName = line.substring(9);
          }
        }
      } catch (_) {
        continue;
      }
      if (!interestingHid(layouts, vid: vid, pid: pid, name: hidName)) continue;
      final path = '$devRoot/$name';
      out.add(FoundDevice(
        key: 'hidraw:$path:${vid?.toRadixString(16)}:${pid?.toRadixString(16)}',
        name: hidName ?? name,
        protocol: Protocol.hid,
        vid: vid,
        pid: pid,
        handle: path,
      ));
    }
    out.sort((a, b) => a.key.compareTo(b.key));
    return out;
  }

  @override
  Future<OpenDevice> open(FoundDevice device) async {
    final path = device.handle as String;
    final fd = _Libc.openPath(path);
    if (fd < 0) {
      final err = _Libc.errno();
      if (err == 13) {
        throw HidPermissionDenied(path);
      }
      throw FileSystemException('open failed (errno $err)', path);
    }
    return _OpenHidraw.start(path, fd);
  }

  @override
  Future<void> dispose() async {
    await _watch?.cancel();
    await _changes?.close();
  }
}

class HidPermissionDenied implements Exception {
  HidPermissionDenied(this.path);
  final String path;
  @override
  String toString() => '$path is not yours to open. Install deploy/udev/99-wetowl-dj.rules '
      '(sudo cp … /etc/udev/rules.d/ && sudo udevadm control --reload && replug).';
}

class _OpenHidraw extends OpenDevice {
  _OpenHidraw._(this.path, this._writeFd);

  static Future<_OpenHidraw> start(String path, int writeFd) async {
    final o = _OpenHidraw._(path, writeFd);
    final ready = Completer<void>();
    o._port = ReceivePort();
    o._port!.listen((msg) {
      if (msg is Uint8List) {
        o._in.add(msg);
      } else if (msg is String) {
        if (msg == 'open') {
          if (!ready.isCompleted) ready.complete();
        } else if (msg.startsWith('error:')) {
          if (!ready.isCompleted) {
            ready.completeError(FileSystemException(msg.substring(6), path));
          } else {
            o._in.addError(FileSystemException(msg.substring(6), path));
            unawaited(o.close());
          }
        } else if (msg == 'done') {
          unawaited(o.close());
        }
      }
    });
    o._isolate = await Isolate.spawn(_readLoop, (path, o._port!.sendPort));
    await ready.future;
    return o;
  }

  final String path;
  final int _writeFd;
  final _in = StreamController<Uint8List>.broadcast();
  ReceivePort? _port;
  Isolate? _isolate;
  bool _closed = false;

  @override
  Stream<Uint8List> get packets => _in.stream;

  @override
  Future<void> send(Uint8List bytes) async {
    final n = _Libc.writeAll(_writeFd, bytes);
    if (n < 0) throw FileSystemException('write failed (errno ${_Libc.errno()})', path);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _port?.close();
    _Libc.close(_writeFd);
    await _in.close();
  }

  /// In its own isolate: open, then poll and read until killed or the device goes.
  static void _readLoop((String, SendPort) args) {
    final (path, port) = args;
    final fd = _Libc.openPath(path);
    if (fd < 0) {
      port.send('error:open failed (errno ${_Libc.errno()})');
      return;
    }
    port.send('open');
    final buf = malloc<Uint8>(256);
    final pfd = malloc<_PollFd>();
    pfd.ref.fd = fd;
    pfd.ref.events = 1; // POLLIN
    try {
      while (true) {
        pfd.ref.revents = 0;
        final r = _Libc.poll(pfd, 1, 500);
        if (r < 0) {
          final err = _Libc.errno();
          if (err == 4) continue; // EINTR
          port.send('error:poll failed (errno $err)');
          return;
        }
        if (r == 0) continue;
        if ((pfd.ref.revents & 0x18) != 0) {
          // POLLERR | POLLHUP: it was pulled out.
          port.send('done');
          return;
        }
        final n = _Libc.read(fd, buf, 256);
        if (n < 0) {
          final err = _Libc.errno();
          if (err == 11 || err == 4) continue; // EAGAIN, EINTR
          port.send(err == 19 ? 'done' : 'error:read failed (errno $err)'); // ENODEV
          return;
        }
        if (n == 0) continue;
        port.send(Uint8List.fromList(buf.asTypedList(n)));
      }
    } finally {
      malloc.free(buf);
      malloc.free(pfd);
      _Libc.close(fd);
    }
  }
}

final class _PollFd extends Struct {
  @Int32()
  external int fd;
  @Int16()
  external int events;
  @Int16()
  external int revents;
}

/// The few libc calls hidraw needs; RandomAccessFile has no O_NONBLOCK.
abstract final class _Libc {
  static final DynamicLibrary _c = DynamicLibrary.process();

  static final int Function(Pointer<Utf8>, int) _open =
      _c.lookup<NativeFunction<Int32 Function(Pointer<Utf8>, Int32)>>('open').asFunction();
  static final int Function(int, Pointer<Uint8>, int) read =
      _c.lookup<NativeFunction<IntPtr Function(Int32, Pointer<Uint8>, IntPtr)>>('read').asFunction();
  static final int Function(int, Pointer<Uint8>, int) _write =
      _c.lookup<NativeFunction<IntPtr Function(Int32, Pointer<Uint8>, IntPtr)>>('write').asFunction();
  static final int Function(int) close = _c.lookup<NativeFunction<Int32 Function(Int32)>>('close').asFunction();
  static final int Function(Pointer<_PollFd>, int, int) poll =
      _c.lookup<NativeFunction<Int32 Function(Pointer<_PollFd>, Uint64, Int32)>>('poll').asFunction();
  static final Pointer<Int32> Function() _errnoLocation =
      _c.lookup<NativeFunction<Pointer<Int32> Function()>>('__errno_location').asFunction();

  static int errno() => _errnoLocation().value;

  /// O_RDWR | O_NONBLOCK | O_CLOEXEC.
  static int openPath(String path) {
    final p = path.toNativeUtf8();
    try {
      return _open(p, 0x2 | 0x800 | 0x80000);
    } finally {
      malloc.free(p);
    }
  }

  static int writeAll(int fd, Uint8List bytes) {
    final p = malloc<Uint8>(bytes.length);
    try {
      p.asTypedList(bytes.length).setAll(0, bytes);
      return _write(fd, p, bytes.length);
    } finally {
      malloc.free(p);
    }
  }
}
