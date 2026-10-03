/// HID on Android: the USB host API, through the app's own channel (Hid.kt).
///
/// A console on an OTG cable is a UsbDevice with a HID interface; the app claims it,
/// reads its interrupt endpoint on a thread and hands each report over. Permission is
/// Android's own dialog the first time, or none at all when the device matches
/// res/xml/usb_devices.xml and the app was opened by plugging it in.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'hid_transport.dart';
import 'layout.dart';
import 'transport.dart';

class AndroidHidTransport extends ControllerTransport {
  AndroidHidTransport(this.layouts);
  final List<ControllerLayout> layouts;

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
    final ok = await _method.invokeMethod<bool>('open', {'id': id}) ?? false;
    if (!ok) throw StateError('Android would not open ${device.name} (no permission, or no HID interface)');
    return _OpenAndroidHid(id, _allPackets.where((m) => m['id'] == id).map((m) => m['bytes'] as Uint8List));
  }
}

class _OpenAndroidHid extends OpenDevice {
  _OpenAndroidHid(this.id, this.packets);
  final String id;
  @override
  final Stream<Uint8List> packets;

  @override
  Future<void> send(Uint8List bytes) =>
      AndroidHidTransport._method.invokeMethod<void>('write', {'id': id, 'bytes': bytes});

  @override
  Future<void> close() => AndroidHidTransport._method.invokeMethod<void>('close', {'id': id});
}
