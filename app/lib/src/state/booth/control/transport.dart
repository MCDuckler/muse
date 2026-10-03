/// How bytes get to and from a controller, whatever the wire.
///
/// A transport finds devices and opens one; what comes back is a stream of packets
/// (one MIDI message, or one HID report) and a way to send some. The MIDI one wraps
/// flutter_midi_command; the HID ones are the app's own, per platform.
library;

import 'dart:async';
import 'dart:typed_data';

import 'layout.dart';

/// A controller that is plugged in, as a transport sees it.
class FoundDevice {
  const FoundDevice({
    required this.key,
    required this.name,
    required this.protocol,
    this.vid,
    this.pid,
    this.handle,
  });

  /// Stable across scans while the device stays plugged in: the transport's own id.
  final String key;
  final String name;
  final Protocol protocol;
  final int? vid, pid;

  /// Whatever the transport needs to open it again.
  final Object? handle;

  String get usbId => vid != null && pid != null
      ? '${vid!.toRadixString(16).padLeft(4, '0')}:${pid!.toRadixString(16).padLeft(4, '0')}'
      : '';

  @override
  String toString() => '$name [${protocol.name}${usbId.isEmpty ? '' : ' $usbId'}]';
}

/// An open controller.
abstract class OpenDevice {
  Stream<Uint8List> get packets;
  Future<void> send(Uint8List bytes);
  Future<void> close();
}

abstract class ControllerTransport {
  Protocol get protocol;

  /// Whether this platform has this wire at all.
  bool get available;

  /// Why not, when it has not — shown in the sheet.
  String? get unavailableWhy => null;

  Future<List<FoundDevice>> scan();

  /// Fires when something is plugged in or pulled out. A transport that cannot tell
  /// gives an empty stream and says [pollsOnly], and the manager rescans now and then.
  Stream<void> get changes;

  bool get pollsOnly => false;

  Future<OpenDevice> open(FoundDevice device);

  Future<void> dispose() async {}
}

/// A transport made of callbacks, for tests and for a virtual controller.
class FakeTransport extends ControllerTransport {
  FakeTransport({this.protocol = Protocol.midi});

  @override
  final Protocol protocol;
  @override
  bool get available => true;

  final devices = <FoundDevice>[];
  final _changes = StreamController<void>.broadcast();
  final opened = <String, FakeOpenDevice>{};

  @override
  Stream<void> get changes => _changes.stream;

  void plug(FoundDevice d) {
    devices.add(d);
    _changes.add(null);
  }

  void unplug(String key) {
    devices.removeWhere((d) => d.key == key);
    opened.remove(key)?._in.close();
    _changes.add(null);
  }

  @override
  Future<List<FoundDevice>> scan() async => List.of(devices);

  @override
  Future<OpenDevice> open(FoundDevice device) async => opened[device.key] = FakeOpenDevice();

  @override
  Future<void> dispose() async => _changes.close();
}

class FakeOpenDevice extends OpenDevice {
  final _in = StreamController<Uint8List>.broadcast();
  final sent = <Uint8List>[];
  bool closed = false;

  @override
  Stream<Uint8List> get packets => _in.stream;

  /// The hardware saying something.
  void say(List<int> bytes) => _in.add(Uint8List.fromList(bytes));

  @override
  Future<void> send(Uint8List bytes) async => sent.add(bytes);

  @override
  Future<void> close() async {
    closed = true;
    await _in.close();
  }
}
