// A server sample's sound on this device: kept under the app's own folder, and handed
// back as a path — the first time, the next time, and to two asking at once.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/booth/board/sample_fetch_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;

  setUp(() {
    support = Directory.systemTemp.createTempSync('wetowl-fetch-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (call) async => support.path);
  });

  tearDown(() => support.deleteSync(recursive: true));

  test('a sound already here comes back as its path, again and again', () async {
    Directory('${support.path}/samples').createSync();
    File('${support.path}/samples/7.audio').writeAsBytesSync([1, 2, 3]);
    final fetch = sampleFetcher(ApiClient(baseUrl: 'http://example.invalid'));
    final want = '${support.path}/samples/7.audio';
    expect(await fetch(7).timeout(const Duration(seconds: 2)), want);
    expect(await fetch(7).timeout(const Duration(seconds: 2)), want, reason: 'and the second time');
    final both = await Future.wait([fetch(7), fetch(7)]).timeout(const Duration(seconds: 2));
    expect(both, [want, want], reason: 'two asking at once share one fetch, and both hear');
  });
}
