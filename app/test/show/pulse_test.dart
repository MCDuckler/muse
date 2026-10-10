// The pulse as the house sends it, read at the needle.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/pulse.dart';

void main() {
  Map<String, dynamic> packed() {
    // Two channels of four frames each: low 0 255 0 255, kick 255 0 0 0.
    final bytes = Uint8List.fromList([0, 255, 0, 255, 255, 0, 0, 0]);
    return {'version': 1, 'hz': 50, 'n': 4, 'channels': ['low', 'kick'], 'data': base64Encode(bytes)};
  }

  test('the channels come apart by name', () {
    final p = Pulse.fromJson(packed());
    expect(p.hz, 50);
    expect(p.n, 4);
    expect(p.has('low'), isTrue);
    expect(p.has('drums'), isFalse);
    expect(p.withStems, isFalse);
    expect(p.length, const Duration(milliseconds: 80));
    expect(p.channels['kick'], [255, 0, 0, 0]);
  });

  test('read between the frames', () {
    final p = Pulse.fromJson(packed());
    expect(p.at('low', Duration.zero), 0);
    expect(p.at('low', const Duration(milliseconds: 20)), 1);
    expect(p.at('low', const Duration(milliseconds: 10)), closeTo(0.5, 1e-9));
    expect(p.at('low', const Duration(milliseconds: 70)), 1, reason: 'the last frame holds');
    expect(p.at('low', const Duration(milliseconds: 90)), 0, reason: 'past the end is nothing');
    expect(p.at('nothing', const Duration(milliseconds: 20)), 0);
  });

  test('the peak over the frames just before', () {
    final p = Pulse.fromJson(packed());
    expect(p.peak('kick', Duration.zero), 1);
    expect(p.peak('kick', const Duration(milliseconds: 40)), 1, reason: 'two frames back is still seen');
    expect(p.peak('kick', const Duration(milliseconds: 60)), 0);
  });

  test('from bytes, and back to JSON', () {
    final p = Pulse.fromBytes(Uint8List.fromList(utf8.encode(jsonEncode(packed()))));
    expect(p.channels['low'], [0, 255, 0, 255]);
    final again = Pulse.fromJson(p.toJson());
    expect(again.channels['kick'], [255, 0, 0, 0]);
  });
}
