/// HID controllers — the Hercules consoles without their driver — on whatever this
/// platform offers: hidraw on Linux, the USB host API on Android, IOKit's HID manager
/// on a Mac, nothing yet on Windows (there, the Hercules driver's MIDI port is the way in).
library;

import 'hid_none.dart' if (dart.library.io) 'hid_io.dart' as io;
import 'layout.dart';
import 'transport.dart';

/// The HID transport for this platform. Always returns one, so the sheet can say why
/// there is no HID here rather than saying nothing.
ControllerTransport hidTransport(List<ControllerLayout> layouts) => io.hidTransport(layouts);

/// A transport this platform has not got.
class NoHid extends ControllerTransport {
  NoHid(this.why);
  final String why;

  @override
  Protocol get protocol => Protocol.hid;
  @override
  bool get available => false;
  @override
  String get unavailableWhy => why;
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  Future<List<FoundDevice>> scan() async => const [];
  @override
  Future<OpenDevice> open(FoundDevice device) => throw UnsupportedError(why);
}

/// Whether a HID device is worth showing: one a layout knows, or one whose name says
/// it is a DJ thing. Keyboards and mice are HID too, and nobody wants them listed.
bool interestingHid(List<ControllerLayout> layouts, {int? vid, int? pid, String? name}) {
  if (layouts.any((l) => l.protocol == Protocol.hid && l.matchesDevice(vid: vid, pid: pid, name: name))) return true;
  final n = (name ?? '').toLowerCase();
  const words = ['dj', 'hercules', 'pioneer', 'numark', 'denon', 'reloop', 'traktor', 'native instruments', 'rane', 'behringer', 'mixtrack', 'ddj'];
  return words.any(n.contains);
}
