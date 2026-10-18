// The stage's picture over the wire: four bytes of size, then the pixels.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/booth/board/link_server.dart';

void main() {
  test('a picture comes back whole, and anything else is nothing', () {
    final px = Uint8List.fromList([for (var i = 0; i < 6 * 4 * 4; i++) i & 0xff]);
    final bytes = encodeStageThumb(6, 4, px);
    final t = parseStageThumb(bytes)!;
    expect(t.width, 6);
    expect(t.height, 4);
    expect(t.rgba, px);
    expect(parseStageThumb(bytes.sublist(0, 10)), isNull);
    expect(parseStageThumb(const [1, 2]), isNull);
    expect(parseStageThumb(encodeStageThumb(2000, 2, Uint8List(2000 * 2 * 4))), isNull);
  });
}
