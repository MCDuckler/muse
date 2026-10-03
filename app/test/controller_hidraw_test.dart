// The Linux HID transport reading the kernel's description of what is plugged in,
// against a pretend /sys tree: a console and a keyboard, and only the console shows.
@TestOn('linux')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/booth/control/hid_linux.dart';
import 'package:muse/src/state/booth/control/layout.dart';

void main() {
  test('hidraw nodes are listed by their uevent, DJ things only', () async {
    final dir = Directory.systemTemp.createTempSync('wetowl-hidraw');
    addTearDown(() => dir.deleteSync(recursive: true));
    void node(String name, String id, String label) {
      final d = Directory('${dir.path}/sys/$name/device')..createSync(recursive: true);
      File('${d.path}/uevent').writeAsStringSync('DRIVER=hid-generic\nHID_ID=$id\nHID_NAME=$label\nHID_PHYS=usb-0000:00:14.0-1/input0\n');
    }
    node('hidraw0', '0003:0000046D:0000C539', 'Logitech USB Receiver');
    node('hidraw1', '0003:000006F8:0000B101', 'Hercules Hercules DJ Console RMX');
    node('hidraw2', '0005:0000054C:00000CE6', 'Wireless Controller');
    final layouts = [ControllerLayout.parse(File('assets/controllers/hercules_dj_console_rmx.hid.json').readAsStringSync())];
    final t = HidrawTransport(layouts, sysRoot: '${dir.path}/sys', devRoot: '${dir.path}/dev');
    expect(t.available, isTrue);
    final found = await t.scan();
    expect(found.map((d) => d.name), ['Hercules Hercules DJ Console RMX']);
    expect(found.single.vid, 0x06f8);
    expect(found.single.pid, 0xb101);
    expect(found.single.usbId, '06f8:b101');
    expect(found.single.handle, '${dir.path}/dev/hidraw1');
    // Opening a node that is not there is a plain error, not a hang.
    await expectLater(t.open(found.single), throwsA(isA<FileSystemException>()));
    await t.dispose();
  });
}
