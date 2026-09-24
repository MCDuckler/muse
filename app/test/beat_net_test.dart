// The beat tracker's frontend and post-processing against the reference: the log-mel
// spectrogram of a second of sound as the Python (numpy, torchaudio's constants)
// makes it, and the peak-picking as the model's own "minimal" post-processor does it.
//
// The network itself runs only where its files are (WETOWL_BEATS_MODEL,
// WETOWL_BEATS_FRONTEND, WETOWL_ORT): then a record with a known grid is tracked.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/separation/beat_net.dart';

void main() {
  final frontendJson = Platform.environment['WETOWL_BEATS_FRONTEND'];

  test('the log-mel spectrogram matches the reference', () {
    if (frontendJson == null) {
      markTestSkipped('needs WETOWL_BEATS_FRONTEND (the model\'s frontend.json)');
      return;
    }
    final fe = BeatFrontend.fromJson(File(frontendJson).readAsStringSync());
    final pcm = File('test/fixtures/beat-frontend.f32').readAsBytesSync();
    final x = pcm.buffer.asFloat32List(pcm.offsetInBytes, pcm.length ~/ 4);
    final want = jsonDecode(File('test/fixtures/beat-frontend-logmel.json').readAsStringSync())
        as Map<String, dynamic>;
    final got = fe.logMel(x);
    expect(BeatFrontend.framesOf(x.length), want['frames']);
    expect(fe.mels, want['mels']);
    final values = (want['values'] as List).cast<num>();
    var worst = 0.0;
    for (var i = 0; i < values.length; i++) {
      worst = (got[i] - values[i]).abs() > worst ? (got[i] - values[i]).abs() : worst;
    }
    expect(worst, lessThan(2e-3), reason: 'largest difference from the reference');
  });

  test('peaks are the model\'s minimal post-processing', () {
    final logits = Float32List(60)..fillRange(0, 60, -3);
    logits[10] = 2.0;
    logits[11] = 2.5;
    logits[30] = 1.0;
    logits[45] = 0.5;
    logits[46] = 0.4;
    expect(peaks(logits), [11.0, 30.0, 45.0]);
    // Two equal side by side: one, between them.
    final pair = Float32List(20)..fillRange(0, 20, -1);
    pair[8] = 1;
    pair[9] = 1;
    expect(peaks(pair), [8.5]);
    // Downbeats go onto the nearest beat, and never twice.
    expect(snapToBeats([9.6, 10.1, 30.2], [10, 20, 30]), [10.0, 30.0]);
  });

  test('a real record is tracked', () {
    final model = Platform.environment['WETOWL_BEATS_MODEL'];
    final ort = Platform.environment['WETOWL_ORT'];
    final record = Platform.environment['WETOWL_BEATS_RECORD'];
    if (model == null || ort == null || frontendJson == null || record == null) {
      markTestSkipped('needs WETOWL_BEATS_MODEL, WETOWL_BEATS_FRONTEND, WETOWL_ORT, WETOWL_BEATS_RECORD');
      return;
    }
    final pcm = File(record).readAsBytesSync(); // f32le mono at 22050
    final x = pcm.buffer.asFloat32List(pcm.offsetInBytes, pcm.length ~/ 4);
    final tracker = BeatTracker.open(
        library: ort, model: model, frontend: BeatFrontend.fromJson(File(frontendJson).readAsStringSync()));
    final found = tracker.track(x);
    tracker.close();
    expect(found.beatsMs.length, greaterThan(100));
    expect(found.downbeatsMs.length, greaterThan(20));
    // ignore: avoid_print
    print(jsonEncode(found.toJson()));
  });
}
