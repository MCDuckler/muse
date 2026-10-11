// MilkDrop's frames off the helper's pipe: gathered whole from reads of any size,
// back in step after something that is not a frame (projectM's shader translator
// printed into the pipe, and the helper was ended and started again for it, on the
// same preset, every second or two), and held back while the stage has one.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/milk_pipe.dart';

Uint8List frameBytes(int w, int h, int fill, {int seq = 0}) {
  final b = BytesBuilder()
    ..add('MILK'.codeUnits)
    ..add((ByteData(12)
          ..setUint32(0, w, Endian.little)
          ..setUint32(4, h, Endian.little)
          ..setUint32(8, seq, Endian.little))
        .buffer
        .asUint8List())
    ..add(List.filled(w * h * 4, fill));
  return b.takeBytes();
}

class Seen {
  Seen({this.take = true});

  /// Each frame taken the moment it comes, as a stage with time on its hands does.
  final bool take;
  final frames = <(int, int, int)>[];
  final said = <String>[];
  var pauses = 0, resumes = 0, gaveUp = 0;
  late final MilkFrames reader = MilkFrames(
    frame: (buf, w, h) {
      frames.add((w, h, buf.bytes[0]));
      if (take) reader.took();
    },
    pause: () => pauses++,
    resume: () => resumes++,
    said: said.add,
    giveUp: () => gaveUp++,
  );

  /// [bytes] in reads of [size].
  void feed(Uint8List bytes, int size) {
    for (var i = 0; i < bytes.length; i += size) {
      reader.add(Uint8List.sublistView(bytes, i, i + size > bytes.length ? bytes.length : i + size));
    }
  }
}

void main() {
  test('frames come whole out of reads of any size', () {
    for (final size in [1, 7, 16, 1000, 65536]) {
      final s = Seen();
      s.feed(Uint8List.fromList([...frameBytes(4, 3, 10), ...frameBytes(4, 3, 20), ...frameBytes(4, 3, 30)]), size);
      expect(s.frames, [(4, 3, 10), (4, 3, 20), (4, 3, 30)], reason: 'reads of $size');
      expect(s.said, isEmpty);
    }
  });

  test('printed noise between frames is skipped, and the frames go on', () {
    final noise = "(88) : Undeclared identifier 'sampler_rand00_smalltiled'\n".codeUnits;
    for (final size in [1, 5, 64, 4096]) {
      final s = Seen();
      s.feed(Uint8List.fromList([...frameBytes(4, 3, 10), ...noise, ...frameBytes(4, 3, 20), ...noise, ...noise, ...frameBytes(4, 3, 30)]), size);
      expect(s.frames, [(4, 3, 10), (4, 3, 20), (4, 3, 30)], reason: 'reads of $size');
      expect(s.said.where((l) => l.contains('back in step')), hasLength(2));
      expect(s.gaveUp, 0);
    }
  });

  test('noise before the first frame, and an M that is not a header', () {
    final s = Seen();
    s.feed(Uint8List.fromList([...'MILKdrop says hello\nM'.codeUnits, ...frameBytes(2, 2, 7)]), 3);
    expect(s.frames, [(2, 2, 7)]);
  });

  test('while the stage has a frame, the newest waits and the pipe is held', () {
    final s = Seen(take: false);
    s.feed(Uint8List.fromList([...frameBytes(2, 2, 1), ...frameBytes(2, 2, 2), ...frameBytes(2, 2, 3)]), 8);
    // The first went out; the second waited and was replaced by the third.
    expect(s.frames, [(2, 2, 1)]);
    expect(s.pauses, 1);
    s.reader.took();
    expect(s.frames, [(2, 2, 1), (2, 2, 3)]);
    expect(s.resumes, 1);
    s.reader.took();
    expect(s.frames, hasLength(2));
    expect(s.resumes, 1);
  });

  test('three buffers at most, and the one with the stage is left alone', () {
    var made = 0;
    MilkBuffer? held;
    late final MilkFrames r;
    r = MilkFrames(
      alloc: (n) {
        made++;
        return (bytes: Uint8List(n), address: made);
      },
      frame: (b, w, h) => held = b,
      pause: () {},
      resume: () {},
      said: (_) {},
      giveUp: () {},
    );
    for (var i = 1; i <= 40; i++) {
      r.add(frameBytes(8, 8, i));
      // The stage reads its frame late, every other one: what it holds is still
      // the frame it was given.
      final b = held!;
      expect(b.bytes.every((x) => x == b.bytes[0]), isTrue);
      if (i.isEven) r.took();
    }
    expect(made, lessThanOrEqualTo(3));
    expect(r.buffers.length, made);
  });

  test('a pipe of nothing but noise gives up', () {
    final s = Seen();
    final junk = Uint8List(1 << 20)..fillRange(0, 1 << 20, 0x41);
    for (var i = 0; i < 70; i++) {
      s.reader.add(junk);
    }
    expect(s.gaveUp, 1);
    expect(s.frames, isEmpty);
  });

  test('the pipe runs a helper on its own isolate', () async {
    // A helper of printf: two frames with a complaint between them, then the first
    // line on stdin back on stderr, and gone.
    String oct(List<int> b) => b.map((x) => '\\${x.toRadixString(8).padLeft(3, '0')}').join();
    final script = "printf '${oct(frameBytes(2, 1, 5))}'; printf 'warning: nonsense\\n'; "
        "printf '${oct(frameBytes(2, 1, 6))}'; echo ready >&2; read line; echo \"got \$line\" >&2";
    final frames = <int>[];
    final said = <String>[];
    final ended = Completer<int>();
    late final MilkPipe pipe;
    pipe = await MilkPipe.start(
      '/bin/sh',
      ['-c', script],
      frame: (rgba, w, h) {
        frames.add(rgba[0]);
        pipe.took();
      },
      said: said.add,
      ended: ended.complete,
    );
    pipe.send('hello there');
    final code = await ended.future.timeout(const Duration(seconds: 10));
    expect(code, 0);
    expect(frames, [5, 6]);
    expect(said, containsAll(['ready', 'got hello there']));
    expect(said.where((l) => l.contains('back in step')), hasLength(1));
  }, skip: Platform.isWindows ? 'no /bin/sh' : null);

  test('a helper that is not there throws', () async {
    await expectLater(
      MilkPipe.start('/no/such/wetowl-milk', const [], frame: (a, b, c) {}, said: (l) {}, ended: (c) {}),
      throwsA(isA<ProcessException>()),
    );
  });
}
