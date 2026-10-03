import '../../../api/client.dart';

/// A browser: no disk to keep a sound on; a pad plays the server's url.
Future<String?> Function(int id) sampleFetcher(ApiClient api) => (id) async => api.sampleAudioUrl(id);

Future<void> forgetSampleFile(int id) async {}
