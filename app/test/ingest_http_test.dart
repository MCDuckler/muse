// The job queue over HTTP, against a real socket: what is sent, how it is signed, and
// what the different kinds of "no" turn into. Both programs that fetch speak through
// this, so a mistake here is a mistake in both.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/worker/downloader.dart';
import 'package:muse/src/worker/ingest_http.dart';

void main() {
  late HttpServer server;
  late HttpIngestServer ingest;
  final seen = <({String path, String? auth, String body, String? type})>[];
  var answer = (200, '{}');
  String? token = 'device-token';

  setUp(() async {
    seen.clear();
    answer = (200, '{}');
    token = 'device-token';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      seen.add((
        path: request.uri.path,
        auth: request.headers.value('authorization'),
        body: body,
        type: request.headers.contentType?.mimeType,
      ));
      request.response.statusCode = answer.$1;
      request.response.write(answer.$2);
      await request.response.close();
    });
    ingest = HttpIngestServer(
        baseUrl: () => 'http://127.0.0.1:${server.port}', token: () => token);
  });
  tearDown(() => server.close(force: true));

  final job = IngestJob(id: 9, trackId: 4, videoId: 'abc123', priority: 100);

  test('asking for work: signed as this device, and jobs that are not jobs are dropped',
      () async {
    answer = (
      200,
      jsonEncode({
        'jobs': [
          {'id': 9, 'priority': 50, 'payload': {'track_id': 4, 'video_id': 'abc123'}},
          {'id': 10, 'payload': {'track_id': 'four'}},
        ]
      })
    );
    final jobs = await ingest.lease(limit: 2, busy: 1, urgentOnly: true);
    expect(jobs.single.videoId, 'abc123');
    expect(seen.single.path, '/internal/jobs/lease');
    expect(seen.single.auth, 'Bearer device-token');
    final asked = jsonDecode(seen.single.body) as Map;
    expect((asked['limit'], asked['busy'], asked['max_priority']), (2, 1, 90));
  });

  test('the token is asked for each time, not remembered', () async {
    await ingest.release(job);
    token = 'after-signing-in-again';
    await ingest.release(job);
    expect(seen.map((s) => s.auth), ['Bearer device-token', 'Bearer after-signing-in-again']);
  });

  test('forbidden is a refusal; anything else is only an error', () async {
    answer = (403, jsonEncode({'detail': 'this device may not fetch'}));
    await expectLater(ingest.lease(limit: 1, busy: 0),
        throwsA(isA<IngestRefused>().having((e) => '$e', 'says why', contains('may not fetch'))));
    answer = (502, 'bad gateway');
    await expectLater(ingest.lease(limit: 1, busy: 0), throwsA(isA<IngestHttpError>()));
  });

  test('a song is handed over as a file with what was found out about it', () async {
    final dir = await Directory.systemTemp.createTemp('wetowl-ingest-test');
    addTearDown(() => dir.delete(recursive: true));
    final audio = File('${dir.path}/abc123.m4a')..writeAsBytesSync(List.filled(2048, 7));
    await ingest.complete(job, audio, {'duration_ms': 1000});
    expect(seen.single.path, '/internal/jobs/9/complete');
    expect(seen.single.type, 'multipart/form-data');
    expect(seen.single.auth, 'Bearer device-token');
    expect(seen.single.body, contains('"duration_ms":1000'));
    expect(seen.single.body, contains('filename="abc123.m4a"'));

    answer = (413, 'too big');
    await expectLater(ingest.complete(job, audio, {}), throwsA(isA<IngestHttpError>()));
  });
}
