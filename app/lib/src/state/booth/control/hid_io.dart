// Which HID transport a dart:io platform gets.
import 'dart:io';

import 'hid_channel.dart';
import 'hid_linux.dart';
import 'hid_transport.dart';
import 'layout.dart';
import 'transport.dart';

ControllerTransport hidTransport(List<ControllerLayout> layouts) {
  if (Platform.isLinux) return HidrawTransport(layouts);
  if (Platform.isAndroid) return ChannelHidTransport(layouts, platform: 'Android');
  if (Platform.isMacOS) return ChannelHidTransport(layouts, platform: 'macOS', pollsOnly: true);
  if (Platform.isIOS) {
    return NoHid('iOS lets an app at MIDI controllers only, never at raw USB HID: '
        'the Hercules RMX cannot be reached from an iPhone or iPad.');
  }
  return NoHid('HID controllers are not reachable on ${Platform.operatingSystem} yet. '
      'With the Hercules driver installed the console shows up as a MIDI port, which works.');
}
