/// A browser has neither ffmpeg nor the cores to spare, so there the parts of a
/// record come from the server or not at all. Nothing here touches a file: this half
/// is what the web build compiles, and it cannot.
const partsVersion = 1;
const upToSeconds = 12 * 60;

/// What this computer can say about a part of a record. Here, always the same thing.
enum Here { ready, making, cannot }

void forgetHere() {}

bool get canSeparateHere => false;

bool makingHere(int trackId, String name) => false;

Future<(Here, String?)> partHere(String audio, int trackId, String name,
        {int? durationMs}) async =>
    (Here.cannot, null);

Future<String> partsDir() async => '';

Future<String?> borrowRecord(
        Uri from, Map<String, String> headers, int trackId) async =>
    null;

Future<void> giveBack(String path) async {}

Future<int> sweepHere() async => 0;
