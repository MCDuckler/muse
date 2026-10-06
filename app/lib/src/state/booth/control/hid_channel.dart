/// HID through the app's own platform channel: Android (Hid.kt, the USB host API)
/// and macOS (Hid.swift, IOKit's HID manager). The two speak the same three channels,
/// so this is the one Dart side for both.
///
/// A console is listed with its USB ids and name; the app claims it, reads its input
/// reports and hands each over as it came (report id first, as hidraw gives them), and
/// takes output reports for the lights. Permission is Android's own dialog the first
/// time, or none at all when the device matches res/xml/usb_devices.xml and the app was
/// opened by plugging it in; a Mac asks nothing for a device that is not a keyboard.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'hid_transport.dart';
import 'layout.dart';
import 'transport.dart';

class ChannelHidTransport extends ControllerTransport {
  ChannelHidTransport(this.layouts, {required this.platform, this.pollsOnly = false});
  final List<ControllerLayout> layouts;

  /// For the notes: which side is talking.
  final String platform;

  /// A Mac's HID manager is never opened (that would open the keyboards too and have
  /// macOS ask for Input Monitoring), and its plug/pull callbacks are listened to but
  /// not leaned on: the manager rescans now and then as well.
  @override
  final bool pollsOnly;

  static const _method = MethodChannel('muse/hid');
  static const _packets = EventChannel('muse/hid/packets');
  static const _changes = EventChannel('muse/hid/changes');

  @override
  Protocol get protocol => Protocol.hid;

  @override
  bool get available => true;

  Stream<Map<Object?, Object?>>? _packetStream;
  Stream<Map<Object?, Object?>> get _allPackets =>
      _packetStream ??= _packets.receiveBroadcastStream().cast<Map<Object?, Object?>>();

  @override
  Stream<void> get changes => _changes.receiveBroadcastStream().map((_) {});

  @override
  Future<List<FoundDevice>> scan() async {
    final list = await _method.invokeListMethod<Map<Object?, Object?>>('list') ?? const [];
    return [
      for (final d in list)
        if (interestingHid(layouts, vid: d['vid'] as int?, pid: d['pid'] as int?, name: d['name'] as String?))
          FoundDevice(
            key: 'usb:${d['id']}',
            name: (d['name'] as String?) ?? 'USB device',
            protocol: Protocol.hid,
            vid: d['vid'] as int?,
            pid: d['pid'] as int?,
            handle: d['id'],
          ),
    ];
  }

  @override
  Future<OpenDevice> open(FoundDevice device) async {
    final id = device.handle as String;
    final bool ok;
    try {
      ok = await _method.invokeMethod<bool>('open', {'id': id}) ?? false;
    } on PlatformException catch (e) {
      throw StateError(e.message ?? '$platform would not open ${device.name}');
    }
    if (!ok) throw StateError('$platform would not open ${device.name} (no permission, or no HID interface)');
    return _OpenChannelHid(id, _allPackets.where((m) => m['id'] == id).map((m) => m['bytes'] as Uint8List));
  }
}

class _OpenChannelHid extends OpenDevice {
  _OpenChannelHid(this.id, this.packets);
  final String id;
  @override
  final Stream<Uint8List> packets;

  @override
  Future<void> send(Uint8List bytes) =>
      ChannelHidTransport._method.invokeMethod<void>('write', {'id': id, 'bytes': bytes});

  @override
  Future<void> close() => ChannelHidTransport._method.invokeMethod<void>('close', {'id': id});
}
