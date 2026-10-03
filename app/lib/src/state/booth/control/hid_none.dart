// The web: no HID from a Flutter app (WebHID exists, but not here yet).
import 'hid_transport.dart';
import 'layout.dart';
import 'transport.dart';

ControllerTransport hidTransport(List<ControllerLayout> layouts) =>
    NoHid('A browser cannot reach HID controllers from here; a MIDI one works through Web MIDI.');
