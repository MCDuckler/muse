import '../../../api/client.dart';

/// A browser: no disk to keep a sound on; a pad plays the server's url — signed, or
/// the server turns the audio element away.
Future<String?> Function(int id) sampleFetcher(ApiClient api) => (id) async {
      try {
        await api.ensureStreamKey();
      } catch (_) {
        // No key to be had: the url as it is, and the server says why.
      }
      return api.sampleAudioUrl(id);
    };

Future<void> forgetSampleFile(int id) async {}
