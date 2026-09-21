/// What yt-dlp is asked, and what its answers mean.
///
/// A port of the decisions in worker/worker.py — the same arguments, the same tables —
/// because those tables are the expensive part: each line in them is a night somebody
/// lost. A rate limit that reads as "Video unavailable" and killed a hundred good songs;
/// an age check that reads like a bot check and put the worker to sleep over and over
/// for one video. The Python worker stays the reference; test/worker_ytdlp_test.dart
/// holds this to the same answers.
library;

/// Errors that will still be errors in five minutes. Retrying these wastes requests
/// against the one thing worth protecting: an unchallenged home connection.
const terminalErrors = [
  'unavailable', 'not available', 'private video', 'removed by the uploader',
  'members-only', 'age-restricted', 'copyright', 'does not exist',
];

/// Not about the song: the connection has been challenged. Give the job back, stop
/// asking for a while, and fetch fewer at a time from here on.
const botCheck = [
  "sign in to confirm you're not a bot", 'sign in to confirm you\u2019re not a bot',
  'not a bot', 'po token', 'login_required',
];

/// This one *is* about the song, and reads almost exactly like a bot check.
const ageCheck = ['confirm your age', 'age-restricted', 'age restricted'];

/// YouTube saying "slow down". It arrives as a warning, while the visible error becomes
/// "Video unavailable" — so it is looked for on every line, not only in the last one.
const rateLimited = ['http error 429', 'too many requests'];

/// A YouTube video id and nothing else: what comes from the server goes on a command
/// line, and although no shell is involved a value that starts with a dash is an option.
final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');

bool isVideoId(String s) => _videoId.hasMatch(s);

/// The command line for one song.
List<String> ytdlpArgs({
  required String videoId,
  required String outDir,
  required String jsRuntime,
  String? cookies,
  String? potProvider,
  String? proxy,
  String? rateLimit,
}) {
  if (!isVideoId(videoId)) throw ArgumentError('not a video id: $videoId');
  return [
    if (potProvider != null) ...[
      '--extractor-args',
      'youtubepot-bgutilhttp:base_url=$potProvider',
    ],
    if (cookies != null) ...['--cookies', cookies],
    if (proxy != null) ...['--proxy', proxy],
    if (rateLimit != null) ...['--limit-rate', rateLimit],
    // Without a JavaScript runtime yt-dlp says extraction is deprecated and that "some
    // formats may be missing" — the one wanted, usually.
    '--js-runtimes', jsRuntime,
    // AAC in an m4a first, so the common path is a copy and not a transcode.
    '-f', '140/bestaudio[acodec^=mp4a]/bestaudio',
    // Warnings stay on: the 429 arrives as one.
    '--no-playlist',
    '-o', '$outDir/%(id)s.%(ext)s',
    // A line a program can read, so the app shows a real bar rather than a spinner.
    '--newline',
    '--progress-template',
    'MUSEPROGRESS %(progress._percent_str)s %(progress._speed_str)s',
    'https://music.youtube.com/watch?v=$videoId',
  ];
}

final _percent = RegExp(r'MUSEPROGRESS\s+([\d.]+)%\s+(\S+)');

/// One line of yt-dlp's output, read.
class YtdlpLine {
  const YtdlpLine({this.percent, this.speed, this.error, this.throttled = false});

  /// 0 to 1, when this was a progress line.
  final double? percent;
  final String? speed;

  /// What this line would be remembered as, if it turns out to be the last word.
  final String? error;
  final bool throttled;

  static YtdlpLine read(String raw) {
    final line = raw.trim();
    final throttled = rateLimited.any(line.toLowerCase().contains);
    final m = _percent.firstMatch(line);
    if (m != null) {
      final p = double.tryParse(m.group(1)!);
      return YtdlpLine(
          percent: p == null ? null : p / 100, speed: m.group(2), throttled: throttled);
    }
    if (line.isEmpty) return YtdlpLine(throttled: throttled);
    // Anything that is not one of yt-dlp's own "[youtube] …" progress notes is a
    // candidate for what went wrong; an ERROR line always is.
    if (line.startsWith('ERROR') ||
        (!line.startsWith('[') && !line.contains('MUSEPROGRESS'))) {
      return YtdlpLine(error: line, throttled: throttled);
    }
    return YtdlpLine(throttled: throttled);
  }
}

/// What to do about a download that did not work.
enum Verdict {
  /// Nothing wrong with the song; the connection is being throttled. Give it back and
  /// stop asking for a while.
  backOff,

  /// YouTube wants an age-verified account. It will not download here.
  needsAge,

  /// Will still be an error in five minutes.
  dead,

  /// Worth another go later.
  retry,
}

Verdict judge({required String lastError, required bool throttled}) {
  final said = lastError.toLowerCase();
  if (throttled) return Verdict.backOff;
  // Before the bot check: "confirm your age" and "confirm you're not a bot" are one
  // word apart, and the first is about the song.
  if (ageCheck.any(said.contains)) return Verdict.needsAge;
  if (botCheck.any(said.contains)) return Verdict.backOff;
  if (terminalErrors.any(said.contains)) return Verdict.dead;
  return Verdict.retry;
}

final _lufs = RegExp(r'^\s*I:\s*(-?\d+\.?\d*)\s*LUFS', multiLine: true);

/// The integrated loudness out of ffmpeg's ebur128 report, and the gain that brings it
/// to the house level. Measured only: nothing is ever baked into the file.
({double? lufs, double? gainDb}) loudnessFrom(String ffmpegStderr, {double target = -14}) {
  // The summary is the last "I:" in the output; the ones before it are running values.
  final all = _lufs.allMatches(ffmpegStderr).toList();
  if (all.isEmpty) return (lufs: null, gainDb: null);
  final lufs = double.parse(all.last.group(1)!);
  return (lufs: lufs, gainDb: double.parse((target - lufs).toStringAsFixed(2)));
}
