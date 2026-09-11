import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// What is on the server, and whether it is newer than what is running.
class Release {
  const Release({
    required this.version,
    required this.build,
    required this.bytes,
    this.built,
  });

  final String version;

  /// The moment it was built, as `YYYYMMDDHHMM`. This is what "newer" means: a stamp
  /// cannot be forgotten to be bumped and is in order by construction, which a
  /// hand-written version number in a source file is not — the one this replaced said
  /// 0.1.0 for every build ever made.
  final String build;

  final int bytes;
  final String? built;

  factory Release.fromJson(Map<String, dynamic> j) => Release(
        version: (j['version'] ?? '?') as String,
        build: '${j['build'] ?? ''}',
        bytes: (j['bytes'] ?? 0) as int,
        built: j['built'] as String?,
      );

  bool isNewerThan(String mine) {
    final theirs = int.tryParse(build);
    if (theirs == null) return false;        // the server has nothing to offer
    final ours = int.tryParse(mine);
    // An app that does not know when it was made was made before any of this existed,
    // which is exactly what every copy installed by hand up to now is. Refusing to
    // offer an update to those was a trap with no way out of it: the first stamped
    // build could never be reached from an unstamped one, so the feature could not
    // install the version that makes the feature work.
    if (ours == null) return true;
    return theirs > ours;
  }

  /// Whether we can say anything about what is running, as opposed to only about what
  /// is on the server.
  static bool knows(String mine) => int.tryParse(mine) != null;

  String get size => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Where an update is up to.
enum Updating { idle, checking, ready, downloading, waiting, failed }

/// Fetching a new version of the app, and asking to install it.
///
/// Worth saying plainly what this can and cannot do: Android will not let anything but
/// a device owner install software without a person saying yes. So the app does
/// everything up to that — notices there is a new version, fetches it, checks it
/// arrived whole — and then asks, once, with one tap. What it does not do is update
/// itself while nobody is looking, and there is no way for it to.
class Updates extends ChangeNotifier {
  Updates({required this.baseUrl, required this.running});

  /// The server the app is talking to. The APK sits beside the web app it came from,
  /// so there is nothing to configure and nowhere else to look.
  String baseUrl;

  /// The build this app was made from, or empty when it was not made by the publisher.
  final String running;

  static const _channel = MethodChannel('muse/install');

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Updating state = Updating.idle;
  Release? release;
  double progress = 0;
  String? trouble;
  File? _fetched;

  bool get available => release != null && release!.isNewerThan(running);

  /// Look, quietly. Anything that goes wrong here is not worth a word: an update
  /// nobody knew about cannot be missed.
  Future<void> look() async {
    if (!supported || state == Updating.downloading) return;
    state = Updating.checking;
    notifyListeners();
    try {
      final r = await http
          .get(Uri.parse('$baseUrl/muse.apk.json'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        final decoded = jsonDecode(r.body);
        if (decoded is Map<String, dynamic>) {
          release = Release.fromJson(decoded);
        }
      }
    } catch (_) {
      // No manifest, no signal, an older server: nothing to say.
    }
    state = available ? Updating.ready : Updating.idle;
    notifyListeners();
  }

  /// Fetch it, then ask to install it.
  Future<void> fetchAndOffer() async {
    final want = release;
    if (!supported || want == null || state == Updating.downloading) return;

    state = Updating.downloading;
    progress = 0;
    trouble = null;
    notifyListeners();

    try {
      final dir = Directory(
          '${(await getApplicationSupportDirectory()).path}/updates');
      await dir.create(recursive: true);
      // One file, replaced each time. Keeping every version ever fetched would quietly
      // fill the phone with sixty-megabyte copies of the same app.
      for (final old in dir.listSync()) {
        try {
          old.deleteSync();
        } catch (_) {}
      }
      final into = File('${dir.path}/muse-${want.build}.apk');

      final request = http.Request('GET', Uri.parse('$baseUrl/muse.apk'));
      final response = await http.Client().send(request);
      if (response.statusCode != 200) {
        throw HttpException('the server answered ${response.statusCode}');
      }
      final total = response.contentLength ?? want.bytes;
      final sink = into.openWrite();
      var had = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        had += chunk.length;
        if (total > 0) {
          final now = had / total;
          // Not on every chunk: this arrives in kilobytes and the bar is a few hundred
          // pixels wide.
          if (now - progress > 0.004 || now >= 1) {
            progress = now;
            notifyListeners();
          }
        }
      }
      await sink.close();

      final got = await into.length();
      // All there, and the right thing. Size is what catches a download cut short,
      // which is the failure that actually happens; anything worse than that — a file
      // altered on the way down — is caught by the installer itself, which checks the
      // signature before it installs anything and is not something this app could do
      // better.
      if (want.bytes > 0 && (got - want.bytes).abs() > 1024) {
        throw const FormatException('it did not all arrive');
      }

      _fetched = into;
      state = Updating.waiting;
      notifyListeners();
      await offer();
    } catch (e) {
      trouble = '$e';
      state = Updating.failed;
      notifyListeners();
    }
  }

  /// Open the system installer on what was fetched.
  Future<void> offer() async {
    final file = _fetched;
    if (!supported || file == null) return;
    try {
      final allowed =
          await _channel.invokeMethod<bool>('allowed') ?? false;
      if (!allowed) {
        // The one setting that grants it, opened directly rather than described.
        await _channel.invokeMethod<void>('allow');
        return;
      }
      final opened =
          await _channel.invokeMethod<bool>('open', {'path': file.path}) ?? false;
      if (!opened) {
        trouble = 'the installer would not open';
        state = Updating.failed;
        notifyListeners();
      }
    } catch (e) {
      trouble = '$e';
      state = Updating.failed;
      notifyListeners();
    }
  }
}
