// The spectrogram arithmetic either side of the network, spread over the cores.
//
// While the network runs it has every core it was given; before and after it, the
// eight inverse transforms of a piece would otherwise run on one thread with the rest
// sitting idle — measured, that was a sixth of the whole time. So they go to helper
// isolates, which read and write the same native memory the network does: nothing is
// copied between them, only which job to do and "done".
import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'scnet.dart';

/// Native memory for one piece's sound, which every helper can see.
class SharedSound {
  SharedSound()
      : _left = malloc<Float>(chunkSamples),
        _right = malloc<Float>(chunkSamples),
        _out = malloc<Float>(8 * chunkSamples);

  final Pointer<Float> _left, _right, _out;

  Float32List get left => _left.asTypedList(chunkSamples);
  Float32List get right => _right.asTypedList(chunkSamples);
  List<Float32List> get out => [
        for (var p = 0; p < 8; p++)
          (_out + p * chunkSamples).asTypedList(chunkSamples),
      ];

  void free() {
    malloc.free(_left);
    malloc.free(_right);
    malloc.free(_out);
  }
}

/// A [Piece] whose transforms run on [helpers] isolates. [specIn] and [specOut] must
/// be native memory (ONNX Runtime's, in the separator), and [sound] the buffers
/// [demix] is given.
class ParallelPiece implements Piece {
  ParallelPiece._(this._network, this._jobs, this._isolates);

  static Future<ParallelPiece> start({
    required void Function() network,
    required Pointer<Float> specIn,
    required Pointer<Float> specOut,
    required SharedSound sound,
    int helpers = 4,
  }) async {
    final addresses = (
      specIn: specIn.address,
      specOut: specOut.address,
      left: sound._left.address,
      right: sound._right.address,
      out: sound._out.address,
    );
    final jobs = <SendPort>[];
    final isolates = <Isolate>[];
    for (var i = 0; i < helpers.clamp(1, 16); i++) {
      final hello = ReceivePort();
      isolates.add(await Isolate.spawn(_helper, (hello.sendPort, addresses)));
      jobs.add(await hello.first as SendPort);
    }
    return ParallelPiece._(network, jobs, isolates);
  }

  final void Function() _network;
  final List<SendPort> _jobs;
  final List<Isolate> _isolates;

  /// Hand out [work] across the helpers and wait for all of it.
  Future<void> _spread(List<int> work) async {
    final back = ReceivePort();
    var left = work.length;
    final done = Completer<void>();
    Object? failed;
    back.listen((m) {
      if (m is String) failed = m;
      if (--left == 0) done.complete();
    });
    for (var i = 0; i < work.length; i++) {
      _jobs[i % _jobs.length].send((work[i], back.sendPort));
    }
    await done.future;
    back.close();
    if (failed != null) throw StateError('a helper failed: $failed');
  }

  /// Where the time went, for WETOWL_SEPARATE_TIMING: in, network, out.
  final Stopwatch inWatch = Stopwatch(), netWatch = Stopwatch(), outWatch = Stopwatch();

  @override
  Future<void> separate(
      Float32List left, Float32List right, List<Float32List> out) async {
    // Jobs 0 and 1 are the two channels in; 2 to 9 the eight signals out.
    inWatch.start();
    await _spread(const [0, 1]);
    inWatch.stop();
    netWatch.start();
    _network();
    netWatch.stop();
    outWatch.start();
    await _spread(const [2, 3, 4, 5, 6, 7, 8, 9]);
    outWatch.stop();
  }

  void close() {
    for (final i in _isolates) {
      i.kill(priority: Isolate.immediate);
    }
  }
}

typedef _Addresses = ({int specIn, int specOut, int left, int right, int out});

void _helper((SendPort, _Addresses) start) {
  final (hello, a) = start;
  final specIn = Pointer<Float>.fromAddress(a.specIn).asTypedList(specInLength);
  final specOut = Pointer<Float>.fromAddress(a.specOut).asTypedList(specOutLength);
  final left = Pointer<Float>.fromAddress(a.left).asTypedList(chunkSamples);
  final right = Pointer<Float>.fromAddress(a.right).asTypedList(chunkSamples);
  final out = [
    for (var p = 0; p < 8; p++)
      Pointer<Float>.fromAddress(a.out + p * chunkSamples * sizeOf<Float>())
          .asTypedList(chunkSamples),
  ];
  final spectra = Spectra();
  final inbox = ReceivePort();
  hello.send(inbox.sendPort);
  inbox.listen((m) {
    final (job, reply) = m as (int, SendPort);
    try {
      if (job < 2) {
        spectra.analyse(job == 0 ? left : right, job, specIn);
      } else {
        spectra.synthesise(specOut, job - 2, out[job - 2]);
      }
      reply.send(true);
    } catch (e) {
      reply.send('$e');
    }
  });
}
