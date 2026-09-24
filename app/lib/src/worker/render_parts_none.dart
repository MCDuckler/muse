/// A browser has neither ffmpeg nor the cores to spare, so there the parts of a
/// record come from the server or not at all. Nothing here touches a file: this half
/// is what the web build compiles, and it cannot.
///
/// Every name the other half offers appears here too, the test-only seams included.
/// The analyser resolves a conditional export to this side, so a name missing here is
/// a name the build says does not exist — however well it works on a desk.
library;

import '../api/models.dart';

const partsVersion = 2;
const trainedParts = ['instrumental', 'drums', 'music', 'vocals', 'stems'];
const serverParts = {'instrumental', 'drums', 'music'};
const upToSeconds = 12 * 60;

String Function()? separationHouse;

set separatorOffForTesting(bool? off) {}

/// What this computer can say about a part of a record. Here, always the same thing.
enum Here { ready, making, cannot }

typedef Renderer = Future<void> Function(
    String audio, String name, Map<String, String> into);

Future<void> _never(String audio, String name, Map<String, String> into) async {}

const Renderer defaultRenderer = _never;
Renderer renderer = defaultRenderer;

set partsDirForTesting(String path) {}

void forgetHere() {}

bool get canSeparateHere => false;

bool makingHere(int trackId, String name) => false;

bool cancelledHere(int trackId) => false;

void forgiveHere(int trackId) {}

void cancelHere(int trackId) {}

void promoteHere(int trackId) {}

Future<bool> canMakeHere(int trackId, String name) async => false;

Future<String?> partReady(int trackId, String name) async => null;

Future<(Here, String?)> partHere(String audio, int trackId, String name,
        {int? durationMs, Track? track}) async =>
    (Here.cannot, null);

Future<String> partsDir() async => '';

Future<String?> borrowRecord(Uri from, Map<String, String> headers, int trackId,
        {void Function(int got, int? total)? progress}) async =>
    null;

Future<void> giveBack(String path) async {}

Future<int> sweepHere() async => 0;

bool unqueueHere(int trackId) => false;


// ignore: avoid_setters_without_getters
set kitDirForTesting(String? path) {}
