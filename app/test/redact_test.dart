import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/redact.dart';

void main() {
  test('tokens and keys are taken out of a log line', () {
    expect(redact('Command: ffmpeg -headers "Authorization: Bearer abc.DEF-123_x=\n" -i https://h/tracks/1/stream?k=2.179.afa4&x=1'),
        'Command: ffmpeg -headers "Authorization: Bearer ***\n" -i https://h/tracks/1/stream?k=***&x=1');
    expect(redact('ws://127.0.0.1:5/stage?t=0123456789abcdef'), 'ws://127.0.0.1:5/stage?t=***');
    expect(redact('nothing secret here, k=1 as a word'), 'nothing secret here, k=1 as a word');
  });
}
