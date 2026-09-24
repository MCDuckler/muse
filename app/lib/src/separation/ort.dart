// Just enough of ONNX Runtime's C API to run one network, on the CPU — or on an
// NVIDIA card through CUDA, with ONNX Runtime's CUDA build and the card's own
// libraries (CUDA and cuDNN) already on the computer.
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
const _appendCudaV2 = 204; // SessionOptionsAppendExecutionProvider_CUDA_V2
const _createCudaOptions = 205;
const _updateCudaOptions = 206;
const _releaseCudaOptions = 208;

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
typedef _UpdateN = _Status Function(
    Pointer<Void>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>, Size);
typedef _Update = _Status Function(
    Pointer<Void>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>, int);
typedef _TwoN = _Status Function(Pointer<Void>, Pointer<Void>);

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
      this._outputs, this._inName, this._outNames, this.input, this.outputs,
      this.version, this.device, this.gpuProblem);

  /// Load [model] with the ONNX Runtime library at [library].
  ///
  /// [inputShape] and [outputShape] are fixed: the memory for both is allocated here,
  /// once, and [input] and [output] are views of it — write the one, [run], read the
  /// other. A network with more than one output names the rest in [moreOutputs]
  /// (name to shape); they are read from [outputs] by name.
  ///
  /// The memory arena is off. With it on, the runtime keeps every buffer it ever
  /// grew, and on SCNet that is gigabytes more at no gain in speed — measured.
  ///
  /// With [cuda], on the graphics card where the library is ONNX Runtime's CUDA build
  /// and the card's libraries load; [device] says where it ended up, and
  /// [gpuProblem] why not the card, when it was asked for and could not be had.
  static OrtNetwork open({
    required String library,
    required String model,
    required String inputName,
    required List<int> inputShape,
    required String outputName,
    required List<int> outputShape,
    Map<String, List<int>> moreOutputs = const {},
    int threads = 4,
    bool cuda = false,
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
    var device = 'cpu';
    String? gpuProblem;
    try {
      _SetInt setInt(int at) => t.at(at).cast<NativeFunction<_SetIntN>>().asFunction<_SetInt>();
      _Plain plain(int at) => t.at(at).cast<NativeFunction<_PlainN>>().asFunction<_Plain>();
      t.check('threads', setInt(_setIntraOpNumThreads)(options, threads));
      t.check('threads', setInt(_setInterOpNumThreads)(options, 1));
      t.check('optimisation', setInt(_setGraphOptimizationLevel)(options, _optimiseAll));
      t.check('arena', plain(_disableCpuMemArena)(options));
      t.check('memory pattern', plain(_disableMemPattern)(options));
      if (cuda) {
        try {
          _appendCuda(t, options);
          device = 'cuda';
        } on OrtError catch (e) {
          gpuProblem = e.message;
        }
      }

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
    final inCount = count(inputShape);
    final inMem = malloc<Float>(inCount);
    final inValue = t.tensor(info, inMem, inCount, inputShape);
    final outs = <(Pointer<Void>, Pointer<Float>)>[];
    final views = <String, Float32List>{};
    final names = <Pointer<Utf8>>[];
    for (final e in [MapEntry(outputName, outputShape), ...moreOutputs.entries]) {
      final n = count(e.value);
      final mem = malloc<Float>(n);
      outs.add((t.tensor(info, mem, n, e.value), mem));
      views[e.key] = mem.asTypedList(n);
      names.add(e.key.toNativeUtf8());
    }

    return OrtNetwork._(
      t,
      env,
      session,
      info,
      (inValue, inMem),
      outs,
      inputName.toNativeUtf8(),
      names,
      inMem.asTypedList(inCount),
      views,
      version,
      device,
      gpuProblem,
    );
  }

  /// The CUDA provider onto [options], ahead of the CPU. The convolution algorithms
  /// are searched for once, at the first run: every piece is the same shape.
  static void _appendCuda(_Table t, Pointer<Void> options) {
    final cudaOptions = using((a) {
      final out = a<Pointer<Void>>();
      t.check('the graphics card',
          t.at(_createCudaOptions).cast<NativeFunction<_OneOutN>>().asFunction<_OneOut>()(out));
      return out.value;
    });
    try {
      using((a) {
        const settings = {'device_id': '0', 'cudnn_conv_algo_search': 'EXHAUSTIVE'};
        final keys = a<Pointer<Utf8>>(settings.length);
        final values = a<Pointer<Utf8>>(settings.length);
        var i = 0;
        for (final e in settings.entries) {
          keys[i] = e.key.toNativeUtf8(allocator: a);
          values[i] = e.value.toNativeUtf8(allocator: a);
          i++;
        }
        t.check(
            'the graphics card',
            t.at(_updateCudaOptions).cast<NativeFunction<_UpdateN>>().asFunction<_Update>()(
                cudaOptions, keys, values, settings.length));
      });
      t.check(
          'the graphics card',
          t.at(_appendCudaV2).cast<NativeFunction<_TwoN>>().asFunction<_TwoN>()(
              options, cudaOptions));
    } finally {
      t.release(_releaseCudaOptions, cudaOptions);
    }
  }

  final _Table _api;
  final Pointer<Void> _env, _session, _info;
  final (Pointer<Void>, Pointer<Float>) _input;
  final List<(Pointer<Void>, Pointer<Float>)> _outputs;
  final Pointer<Utf8> _inName;
  final List<Pointer<Utf8>> _outNames;

  /// Where to write what goes in.
  final Float32List input;

  /// Where to read what came out, by output name; [output] is the first.
  final Map<String, Float32List> outputs;
  Float32List get output => outputs.values.first;

  /// Which ONNX Runtime this is.
  final String version;

  /// Where the network runs: 'cuda' or 'cpu'.
  final String device;

  /// Why not the graphics card, where it was asked for and could not be had.
  final String? gpuProblem;

  /// The same two blocks as pointers, for other isolates to see.
  Pointer<Float> get inputPointer => _input.$2;
  Pointer<Float> get outputPointer => _outputs.first.$2;

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
      final ins = a<Pointer<Void>>()..value = _input.$1;
      final n = _outputs.length;
      final outNames = a<Pointer<Utf8>>(n);
      final outs = a<Pointer<Void>>(n);
      for (var i = 0; i < n; i++) {
        outNames[i] = _outNames[i];
        outs[i] = _outputs[i].$1;
      }
      _runFn(_session, nullptr, inNames, ins, 1, outNames, n, outs);
    });
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _api.release(_releaseValue, _input.$1);
    malloc.free(_input.$2);
    for (final (value, mem) in _outputs) {
      _api.release(_releaseValue, value);
      malloc.free(mem);
    }
    malloc.free(_inName);
    for (final n in _outNames) {
      malloc.free(n);
    }
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
