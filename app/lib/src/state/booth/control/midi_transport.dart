/// MIDI controllers, through flutter_midi_command: USB-MIDI on every platform,
/// CoreMIDI on Apple's, ALSA's sequencer on Linux, Web MIDI in a browser.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_midi_command/flutter_midi_command.dart';

import 'layout.dart';
import 'transport.dart';

class MidiTransport extends ControllerTransport {
  MidiTransport({MidiCommand? midi}) : _midi = midi ?? MidiCommand();

  final MidiCommand _midi;

  @override
  Protocol get protocol => Protocol.midi;

  @override
  bool get available => true;

  @override
  Stream<void> get changes => _midi.onMidiSetupChanged?.map((_) {}) ?? const Stream.empty();

  @override
  Future<List<FoundDevice>> scan() async {
    final devices = await _midi.devices ?? const <MidiDevice>[];
    return [
      for (final d in devices)
        // Something has to come *from* it: an output-only port is a synth, not a deck.
        if (d.inputPorts.isNotEmpty || d.type == MidiDeviceType.ble)
          FoundDevice(key: 'midi:${d.id}', name: d.name, protocol: Protocol.midi, handle: d),
    ];
  }

  @override
  Future<OpenDevice> open(FoundDevice device) async {
    final d = device.handle as MidiDevice;
    await _midi.connectToDevice(d, awaitConnectionTimeout: const Duration(seconds: 8));
    return _OpenMidi(_midi, d);
  }

  @override
  Future<void> dispose() async => _midi.dispose();
}

class _OpenMidi extends OpenDevice {
  _OpenMidi(this._midi, this.device);
  final MidiCommand _midi;
  final MidiDevice device;

  @override
  Stream<Uint8List> get packets =>
      (_midi.onMidiPacketReceived ?? const Stream<MidiPacket>.empty())
          .where((p) => p.device.id == device.id)
          .map((p) => p.data);

  @override
  Future<void> send(Uint8List bytes) async => _midi.sendData(bytes, deviceId: device.id);

  @override
  Future<void> close() async => _midi.disconnectDevice(device);
}
