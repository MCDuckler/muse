// Just enough of ONNX Runtime's C API to run one network on the CPU.
//
// There is no maintained Dart binding for desktop, and the Flutter plugin that
// exists runs the network on the window's own thread — which is a frozen window for
// a second and a half at a time. This is used from the windowless separator
// instead, a process of its own, where blocking is the whole job.
//
// The C API is one table of function pointers (OrtApi) that only ever grows at the
// end, so a function's place in it is fixed forever. The places below were read out
// of onnxruntime_c_api.h for 1.30; see tools/separation/README.md for how, if a newer
// function is ever wanted.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// Places in the OrtApi table.
const _getErrorMessage = 2;
const _createEnv = 3;
const _createSession = 7;
const _run = 9;
const _createSessionOptions = 10;
const _disableMemPattern = 17;
const _disableCpuMemArena = 19;
const _setGraphOptimizationLevel = 23;
const _setIntraOpNumThreads = 24;
const _setInterOpNumThreads = 25;
const _createTensorWithData = 49;
const _createCpuMemoryInfo = 69;
const _releaseEnv = 92;
const _releaseStatus = 93;
const _releaseMemoryInfo = 94;
const _releaseSession = 95;
const _releaseValue = 96;
const _releaseSessionOptions = 100;

/// The oldest table that has everything above. Asking for an old version of the
/// table is always allowed; every newer library still hands it out.
const _apiVersion = 16;

const _loggingError = 3; // ORT_LOGGING_LEVEL_ERROR
const _optimiseAll = 99; // ORT_ENABLE_ALL
const _arenaAllocator = 1; // OrtArenaAllocator
const _memTypeDefault = 0; // OrtMemTypeDefault
const _float = 1; // ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT

final class _ApiBase extends Struct {
  external Pointer<NativeFunction<Pointer<Pointer<Void>> Function(Uint32)>> getApi;
  external Pointer<NativeFunction<Pointer<Utf8> Function()>> getVersionString;
}

typedef _Status = Pointer<Void>;
typedef _OneOut = _Status Function(Pointer<Pointer<Void>>);
typedef _ReleaseN = Void Function(Pointer<Void>);
typedef _Release = void Function(Pointer<Void>);
typedef _CreateEnvN = _Status Function(Int32, Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _CreateEnv = _Status Function(int, Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _OneOutN = _Status Function(Pointer<Pointer<Void>>);
typedef _SetIntN = _Status Function(Pointer<Void>, Int32);
typedef _SetInt = _Status Function(Pointer<Void>, int);
typedef _PlainN = _Status Function(Pointer<Void>);
typedef _Plain = _Status Function(Pointer<Void>);
typedef _CreateSessionN = _Status Function(
    Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _MemInfoN = _Status Function(Int32, Int32, Pointer<Pointer<Void>>);
typedef _MemInfo = _Status Function(int, int, Pointer<Pointer<Void>>);
typedef _RunN = _Status Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Void>>, Size, Pointer<Pointer<Utf8>>, Size, Pointer<Pointer<Void>>);
typedef _Run = _Status Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Void>>, int, Pointer<Pointer<Utf8>>, int, Pointer<Pointer<Void>>);
typedef _TensorN = _Status Function(Pointer<Void>, Pointer<Void>, Size, Pointer<Int64>,
    Size, Int32, Pointer<Pointer<Void>>);
typedef _Tensor = _Status Function(Pointer<Void>, Pointer<Void>, int, Pointer<Int64>,
    int, int, Pointer<Pointer<Void>>);
typedef _MessageN = Pointer<Utf8> Function(Pointer<Void>);

/// Something ONNX Runtime said went wrong, in its own words.
class OrtError implements Exception {
  OrtError(this.what, this.message);
  final String what;
  final String message;
  @override
  String toString() => 'onnxruntime: $what: $message';
}

/// One network, loaded and ready, reading from and writing to two blocks of memory
/// that stay put for as long as it is open.
class OrtNetwork {
  OrtNetwork._(this._api, this._env, this._session, this._info, this._input,
      this._output, this._inName, this._outName, this.input, this.output,
      this.version);

  /// Load [model] with the ONNX Runtime library at [library].
  ///
  /// [inputShape] and [outputShape] are fixed: the memory for both is allocated here,
  /// once, and [input] and [output] are views of it — write the one, [run], read the
  /// other.
  ///
  /// The memory arena is off. With it on, the runtime keeps every buffer it ever
  /// grew, and on SCNet that is gigabytes more at no gain in speed — measured.
  static OrtNetwork open({
    required String library,
    required String model,
    required String inputName,
    required List<int> inputShape,
    required String outputName,
    required List<int> outputShape,
    int threads = 4,
  }) {
    final lib = DynamicLibrary.open(library);
    final base = lib
        .lookupFunction<Pointer<_ApiBase> Function(), Pointer<_ApiBase> Function()>(
            'OrtGetApiBase')();
    final api = base.ref.getApi
        .asFunction<Pointer<Pointer<Void>> Function(int)>()(_apiVersion);
    if (api == nullptr) {
      throw OrtError('start', 'this library does not offer API version $_apiVersion');
    }
    final version = base.ref.getVersionString.asFunction<Pointer<Utf8> Function()>()()
        .toDartString();
    final t = _Table(api);

    final env = using((a) {
      final out = a<Pointer<Void>>();
      t.check(
          'environment',
          t.at(_createEnv).cast<NativeFunction<_CreateEnvN>>().asFunction<_CreateEnv>()(
              _loggingError, 'wetowl'.toNativeUtf8(allocator: a), out));
      return out.value;
    });

    final options = using((a) {
      final out = a<Pointer<Void>>();
      t.check('options',
          t.at(_createSessionOptions).cast<NativeFunction<_OneOutN>>().asFunction<_OneOut>()(out));
      return out.value;
    });
    Pointer<Void> session;
    try {
      _SetInt setInt(int at) => t.at(at).cast<NativeFunction<_SetIntN>>().asFunction<_SetInt>();
      _Plain plain(int at) => t.at(at).cast<NativeFunction<_PlainN>>().asFunction<_Plain>();
      t.check('threads', setInt(_setIntraOpNumThreads)(options, threads));
      t.check('threads', setInt(_setInterOpNumThreads)(options, 1));
      t.check('optimisation', setInt(_setGraphOptimizationLevel)(options, _optimiseAll));
      t.check('arena', plain(_disableCpuMemArena)(options));
      t.check('memory pattern', plain(_disableMemPattern)(options));

      session = using((a) {
        final out = a<Pointer<Void>>();
        // A path is wide characters on Windows and bytes everywhere else.
        final path = Platform.isWindows
            ? model.toNativeUtf16(allocator: a).cast<Void>()
            : model.toNativeUtf8(allocator: a).cast<Void>();
        t.check(
            'loading the model',
            t.at(_createSession)
                .cast<NativeFunction<_CreateSessionN>>()
                .asFunction<_CreateSessionN>()(env, path, options, out));
        return out.value;
      });
    } finally {
      t.release(_releaseSessionOptions, options);
    }

    final info = using((a) {
      final out = a<Pointer<Void>>();
      t.check(
          'memory',
          t.at(_createCpuMemoryInfo).cast<NativeFunction<_MemInfoN>>().asFunction<_MemInfo>()(
              _arenaAllocator, _memTypeDefault, out));
      return out.value;
    });

    int count(List<int> shape) => shape.fold(1, (a, b) => a * b);
    final inCount = count(inputShape), outCount = count(outputShape);
    final inMem = malloc<Float>(inCount), outMem = malloc<Float>(outCount);
    final inValue = t.tensor(info, inMem, inCount, inputShape);
    final outValue = t.tensor(info, outMem, outCount, outputShape);

    return OrtNetwork._(
      t,
      env,
      session,
      info,
      (inValue, inMem),
      (outValue, outMem),
      inputName.toNativeUtf8(),
      outputName.toNativeUtf8(),
      inMem.asTypedList(inCount),
      outMem.asTypedList(outCount),
      version,
    );
  }

  final _Table _api;
  final Pointer<Void> _env, _session, _info;
  final (Pointer<Void>, Pointer<Float>) _input, _output;
  final Pointer<Utf8> _inName, _outName;

  /// Where to write what goes in, and where to read what came out.
  final Float32List input, output;

  /// Which ONNX Runtime this is.
  final String version;

  /// The same two blocks as pointers, for other isolates to see.
  Pointer<Float> get inputPointer => _input.$2;
  Pointer<Float> get outputPointer => _output.$2;

  bool _closed = false;

  late final _Run _runFn0 = _api.at(_run).cast<NativeFunction<_RunN>>().asFunction<_Run>();
  void _runFn(Pointer<Void> s, Pointer<Void> o, Pointer<Pointer<Utf8>> inNames,
          Pointer<Pointer<Void>> ins, int inCount, Pointer<Pointer<Utf8>> outNames,
          int outCount, Pointer<Pointer<Void>> outs) =>
      _api.check('running', _runFn0(s, o, inNames, ins, inCount, outNames, outCount, outs));

  /// One pass of the network, from [input] into [output].
  void run() {
    if (_closed) throw StateError('closed');
    using((a) {
      final inNames = a<Pointer<Utf8>>()..value = _inName;
      final outNames = a<Pointer<Utf8>>()..value = _outName;
      final ins = a<Pointer<Void>>()..value = _input.$1;
      final outs = a<Pointer<Void>>()..value = _output.$1;
      _runFn(_session, nullptr, inNames, ins, 1, outNames, 1, outs);
    });
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _api.release(_releaseValue, _input.$1);
    _api.release(_releaseValue, _output.$1);
    malloc.free(_input.$2);
    malloc.free(_output.$2);
    malloc.free(_inName);
    malloc.free(_outName);
    _api.release(_releaseMemoryInfo, _info);
    _api.release(_releaseSession, _session);
    _api.release(_releaseEnv, _env);
  }
}

class _Table {
  _Table(this._slots);
  final Pointer<Pointer<Void>> _slots;

  Pointer<Void> at(int slot) => _slots[slot];

  void check(String what, _Status status) {
    if (status == nullptr) return;
    final message = at(_getErrorMessage)
        .cast<NativeFunction<_MessageN>>()
        .asFunction<_MessageN>()(status)
        .toDartString();
    release(_releaseStatus, status);
    throw OrtError(what, message);
  }

  void release(int at, Pointer<Void> p) {
    if (p == nullptr) return;
    this.at(at).cast<NativeFunction<_ReleaseN>>().asFunction<_Release>()(p);
  }

  Pointer<Void> tensor(
      Pointer<Void> info, Pointer<Float> data, int count, List<int> shape) {
    return using((a) {
      final dims = a<Int64>(shape.length);
      for (var i = 0; i < shape.length; i++) {
        dims[i] = shape[i];
      }
      final out = a<Pointer<Void>>();
      check(
          'a tensor',
          at(_createTensorWithData).cast<NativeFunction<_TensorN>>().asFunction<_Tensor>()(
              info, data.cast(), count * 4, dims, shape.length, _float, out));
      return out.value;
    });
  }
}
