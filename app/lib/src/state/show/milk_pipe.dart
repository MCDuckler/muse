// The wetowl-milk helper's pipes, on an isolate of their own.
//
// A frame is two megabytes, and dart:io reads a child's stdout in turns of at most
// 64 KB, each turn started only once the isolate has taken the last — on Windows
// through a pipe of 1 KB, so the helper's write waits on every turn. Thirty-odd
// round trips a frame, sixty frames a second: on the UI isolate that was every gap
// between the app's own frames, and the stage and the app both went slow with it.
// Here the frame is gathered whole and handed over once, and only when the stage
// has taken the one before. While it has not, the pipe is left to fill, which holds
// the helper's render back on its write rather than drawing frames no one will see.
//
// Handed over in memory of the process's own (malloc), not the Dart heap: a fresh
// two megabytes a frame in the UI isolate's heap — sixty times a second, a copy
// sent or a transferable materialised — had its collector marking the whole app
// over and over, which cost more than the pipe. The pipe's isolate gathers into a
// few buffers it keeps; the UI isolate reads one in place for the length of the
// call (decodeImageFromPixels copies it, there and then) and says when it has.
// They are freed by the UI isolate after the helper's end, when nothing can be
// reading them.
//
// The commands go the other way as they are: a line, and a payload where it has one.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// A frame's pixels: the bytes, and where they are (0 for a Dart buffer).
typedef MilkBuffer = ({Uint8List bytes, int address});

class MilkPipe {
  MilkPipe._();

  late final SendPort _to;
  bool _closed = false;

  /// The helper at [path], started on the pipe's isolate. [frame] has each frame
  /// (RGBA, top row first), good for the length of the call only, and must answer
  /// with [took] when the next may come;
  /// [said] has the helper's stderr by line; [ended] its exit (or the pipe's own
  /// trouble, as [said] first). Throws where the helper would not start.
  static Future<MilkPipe> start(
    String path,
    List<String> args, {
    required void Function(Uint8List rgba, int width, int height) frame,
    required void Function(String line) said,
    required void Function(int code) ended,
  }) async {
    final from = ReceivePort('milk pipe');
    final hello = Completer<void>();
    final pipe = MilkPipe._();
    void end(int code) {
      from.close();
      if (!hello.isCompleted) hello.completeError(ProcessException(path, args, 'the pipe ended before it began'));
      if (pipe._closed) return;
      pipe._closed = true;
      ended(code);
    }

    from.listen((m) {
      // The isolate's own end (onExit): after its last word, or in place of it.
      if (m == null) return end(-1);
      if (m is SendPort) {
        pipe._to = m;
        hello.complete();
        return;
      }
      final msg = m as List<Object?>;
      switch (msg[0]) {
        case 'failed':
          from.close();
          pipe._closed = true;
          hello.completeError(ProcessException(path, args, msg[1] as String));
        case 'frame':
          if (!pipe._closed) frame(Pointer<Uint8>.fromAddress(msg[3] as int).asTypedList(msg[4] as int), msg[1] as int, msg[2] as int);
        case 'said':
          said(msg[1] as String);
        case 'ended':
          end(msg[1] as int);
          // Every frame before this has been read: the buffers can go.
          for (final a in msg[2] as List<int>) {
            malloc.free(Pointer<Uint8>.fromAddress(a));
          }
      }
    });
    try {
      await Isolate.spawn(_run, (from.sendPort, path, args), debugName: 'milk pipe', onExit: from.sendPort);
      await hello.future;
      return pipe;
    } catch (_) {
      from.close();
      rethrow;
    }
  }

  /// A command: [line] and, where it has one, its payload.
  void send(String line, [Uint8List? payload]) {
    if (!_closed) _to.send([line, payload]);
  }

  /// The last frame is done with: the next may come.
  void took() {
    if (!_closed) _to.send(const ['took']);
  }

  /// Quit asked, and the helper ended (no [ended] call for it).
  void stop() {
    if (_closed) return;
    _closed = true;
    _to.send(const ['stop']);
  }

  // ------------------------------------------------------------- the isolate
  static Future<void> _run((SendPort, String, List<String>) a) async {
    final (out, path, args) = a;
    final Process proc;
    try {
      proc = await Process.start(path, args);
    } catch (e) {
      out.send(['failed', '$e']);
      return;
    }
    final inbox = ReceivePort();
    late final StreamSubscription<List<int>> sub;
    final frames = MilkFrames(
      alloc: (n) {
        final p = malloc<Uint8>(n);
        return (bytes: p.asTypedList(n), address: p.address);
      },
      release: (b) => malloc.free(Pointer<Uint8>.fromAddress(b.address)),
      frame: (b, w, h) => out.send(['frame', w, h, b.address, b.bytes.length]),
      pause: () => sub.pause(),
      resume: () => sub.resume(),
      said: (l) => out.send(['said', l]),
      giveUp: () {
        unawaited(sub.cancel());
        proc.kill();
      },
    );
    var stopping = false;
    // A helper gone mid-write: its exit says so.
    unawaited(proc.stdin.done.then((_) {}, onError: (_) {}));
    final drained = Completer<void>();
    sub = proc.stdout.listen(frames.add, onDone: drained.complete);
    proc.stderr.transform(const SystemEncoding().decoder).transform(const LineSplitter()).listen((l) => out.send(['said', l]));
    inbox.listen((m) {
      final msg = m as List<Object?>;
      switch (msg[0]) {
        case 'took':
          frames.took();
        case 'stop':
          stopping = true;
          try {
            proc.stdin.write('quit\n');
          } catch (_) {}
          proc.kill();
        default:
          try {
            proc.stdin.write('${msg[0]}\n');
            final payload = msg[1] as Uint8List?;
            if (payload != null) proc.stdin.add(payload);
          } catch (_) {
            // The pipe is gone: the exit will say so.
          }
      }
    });
    out.send(inbox.sendPort);
    final code = await proc.exitCode;
    // What it wrote before it went, while the stage is still taking frames.
    await Future.any([drained.future, Future<void>.delayed(const Duration(seconds: 1))]);
    if (frames.trouble != null) out.send(['said', frames.trouble]);
    out.send(['ended', stopping ? 0 : code, [for (final b in frames.buffers) b.address]]);
    inbox.close();
    await sub.cancel();
  }
}

/// The frames off the helper's stdout: "MILK" + u32 width + u32 height + u32
/// sequence, then the pixels. One is with the stage at a time; one more may wait,
/// the newest, and while one waits the pipe is not read.
///
/// Out of step — something other than frames on the pipe — the next header is
/// looked for and the frames go on from it: ending the helper for it (as was done)
/// starts it again on the same preset, which says the same thing again.
class MilkFrames {
  MilkFrames({required this.frame, required this.pause, required this.resume, required this.said, required this.giveUp, MilkBuffer Function(int n)? alloc, this.release})
      : alloc = alloc ?? ((n) => (bytes: Uint8List(n), address: 0));

  /// A frame for the stage: its buffer is the stage's until [took].
  final void Function(MilkBuffer rgba, int width, int height) frame;

  /// Where the buffers come from, and go when they no longer fit the frames.
  final MilkBuffer Function(int n) alloc;
  final void Function(MilkBuffer b)? release;

  /// The pipe held, and let go.
  final void Function() pause, resume;
  final void Function(String line) said;

  /// The pipe has been nothing but noise for too long.
  final void Function() giveUp;
  String? trouble;
  bool _paused = false;

  static const _header = 16;
  final _head = Uint8List(_header);
  int _cursor = 0, _w = 0, _h = 0;

  /// The pixels' buffers, three at most: the one with the stage, the one waiting,
  /// the one being gathered.
  final _spare = <MilkBuffer>[];
  MilkBuffer? _waiting, _out, _gathering;
  int _waitingW = 0, _waitingH = 0;

  /// Every buffer there is: for whoever frees them, after the end.
  Iterable<MilkBuffer> get buffers => [..._spare, _waiting, _out, _gathering].whereType<MilkBuffer>();

  MilkBuffer _buffer(int n) {
    while (_spare.isNotEmpty) {
      final b = _spare.removeLast();
      if (b.bytes.length == n) return b;
      release?.call(b);
    }
    return alloc(n);
  }

  /// Looking for the next header: the bytes since the step was lost, the last few
  /// kept in case a header straddles two reads.
  bool _hunting = false;
  Uint8List _tail = Uint8List(0);
  int _lost = 0;

  static bool _sane(int w, int h) => w > 0 && w <= 8192 && h > 0 && h <= 8192;

  /// Where "MILK" + this width + this height starts in [b], or -1.
  int _header0(Uint8List b) {
    for (var i = 0; i + 12 <= b.length; i++) {
      if (b[i] != 0x4d || b[i + 1] != 0x49 || b[i + 2] != 0x4c || b[i + 3] != 0x4b) continue;
      final bd = ByteData.sublistView(b, i + 4, i + 12);
      final w = bd.getUint32(0, Endian.little), h = bd.getUint32(4, Endian.little);
      if (_w == 0 ? _sane(w, h) : (w == _w && h == _h)) return i;
    }
    return -1;
  }

  void add(List<int> chunk) {
    var c = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    if (_hunting) {
      final joined = Uint8List(_tail.length + c.length)
        ..setAll(0, _tail)
        ..setAll(_tail.length, c);
      final at = _header0(joined);
      if (at < 0) {
        _lost += c.length;
        _tail = joined.sublist(math.max(0, joined.length - 11));
        // A pipe of nothing but noise: the helper is past help.
        if (_lost > 64 << 20 && trouble == null) {
          trouble = 'MilkDrop frames out of step';
          giveUp();
        }
        return;
      }
      said('frames back in step, ${_lost - _tail.length + at + 1} bytes skipped');
      _hunting = false;
      _tail = Uint8List(0);
      c = joined.sublist(at);
    }
    var off = 0;
    while (off < c.length) {
      final buf = _gathering;
      if (buf == null) {
        final n = math.min(_header - _cursor, c.length - off);
        _head.setRange(_cursor, _cursor + n, c, off);
        _cursor += n;
        off += n;
        if (_cursor < _header) return;
        _cursor = 0;
        final bd = ByteData.sublistView(_head);
        if (bd.getUint32(0, Endian.little) != 0x4b4c494d || !_sane(bd.getUint32(4, Endian.little), bd.getUint32(8, Endian.little))) {
          // Out of step: the header is looked for from here.
          _hunting = true;
          _lost = 0;
          _tail = Uint8List(0);
          final rest = Uint8List(_header + c.length - off)
            ..setAll(0, _head)
            ..setAll(_header, Uint8List.sublistView(c, off));
          // The 'M' that began this false header is not a header: from the byte after.
          add(Uint8List.sublistView(rest, 1));
          return;
        }
        _w = bd.getUint32(4, Endian.little);
        _h = bd.getUint32(8, Endian.little);
        _gathering = _buffer(_w * _h * 4);
        continue;
      }
      final bytes = buf.bytes;
      final n = math.min(bytes.length - _cursor, c.length - off);
      bytes.setRange(_cursor, _cursor + n, c, off);
      _cursor += n;
      off += n;
      if (_cursor < bytes.length) continue;
      _gathering = null;
      _cursor = 0;
      if (_out == null) {
        _send(buf, _w, _h);
      } else {
        // The stage still has one: this waits, in place of any that waited, and
        // the pipe is left until the stage is done.
        final was = _waiting;
        if (was != null) _spare.add(was);
        _waiting = buf;
        _waitingW = _w;
        _waitingH = _h;
        if (!_paused) {
          _paused = true;
          pause();
        }
      }
    }
  }

  void _send(MilkBuffer buf, int w, int h) {
    _out = buf;
    frame(buf, w, h);
  }

  void took() {
    final was = _out;
    if (was == null) return;
    _out = null;
    _spare.add(was);
    final w = _waiting;
    if (w != null) {
      _waiting = null;
      _send(w, _waitingW, _waitingH);
    }
    if (_paused) {
      _paused = false;
      resume();
    }
  }
}
