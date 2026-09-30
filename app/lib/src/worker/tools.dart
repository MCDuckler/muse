import 'dart:io';

/// The programs the downloader runs, and where they are.
///
/// yt-dlp to fetch, ffmpeg and ffprobe to look at and (rarely) convert what it fetched,
/// and a JavaScript runtime because yt-dlp needs one to read YouTube's player. Looked
/// for first in the app's own tools folder, then on the PATH — on Linux they are nearly
/// always a package away and the distribution's copy is the one that gets security
/// fixes, and on a Mac, Homebrew's. What is missing is named, with what to do about it.
class Tools {
  Tools({required this.ytdlp, required this.ffmpeg, required this.ffprobe, required this.js});

  final String? ytdlp;
  final String? ffmpeg;
  final String? ffprobe;

  /// 'node' or 'deno', as yt-dlp's --js-runtimes wants it said.
  final ({String name, String path})? js;

  bool get ready => ytdlp != null && ffmpeg != null && ffprobe != null && js != null;

  List<String> get missing => [
        if (ytdlp == null) 'yt-dlp',
        if (ffmpeg == null) 'ffmpeg',
        if (ffprobe == null) 'ffprobe',
        if (js == null) 'node or deno',
      ];

  /// What to type, for whoever has to install them.
  static String howToInstall(List<String> missing) {
    if (missing.isEmpty) return '';
    final wanted = {
      for (final m in missing)
        if (m == 'ffprobe') 'ffmpeg' else if (m == 'node or deno') 'nodejs' else m
    }.join(' ');
    if (Platform.isWindows) {
      return 'winget install ${{
        for (final m in missing)
          if (m.startsWith('ff')) 'Gyan.FFmpeg' else if (m == 'yt-dlp') 'yt-dlp.yt-dlp' else 'DenoLand.Deno'
      }.join(' ')}';
    }
    if (Platform.isMacOS) {
      // Homebrew's names, and deno rather than node: one small program, where Homebrew's
      // node brings a compiler's worth of libraries with it.
      return 'brew install ${{
        for (final m in missing)
          if (m.startsWith('ff')) 'ffmpeg' else if (m == 'yt-dlp') 'yt-dlp' else 'deno'
      }.join(' ')}';
    }
    return 'pacman -S $wanted   ·   apt install $wanted   ·   dnf install $wanted';
  }

  /// Where to get each of them, for whoever would rather click than type: the
  /// project's own page every time, never a mirror. The direct file where a project
  /// publishes one that simply runs; its download page where there is a choice to make.
  static List<ToolLink> linksFor(List<String> missing, {bool? windows, bool? mac}) {
    final win = windows ?? Platform.isWindows;
    if (mac ?? Platform.isMacOS) return _macLinks(missing);
    return [
      if (missing.contains('yt-dlp'))
        ToolLink(
          'yt-dlp',
          'fetches the audio',
          win
              ? 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
              : 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux',
          win
              ? 'One file. Put it in the tools folder as yt-dlp.exe.'
              : 'One file. Put it in the tools folder as yt-dlp and make it executable '
                  '(chmod +x) — or install your distribution\'s package.',
        ),
      if (missing.contains('ffmpeg') || missing.contains('ffprobe'))
        ToolLink(
          'ffmpeg and ffprobe',
          'look at what was fetched, and convert it when it has to be',
          win ? 'https://www.gyan.dev/ffmpeg/builds/' : 'https://ffmpeg.org/download.html#build-linux',
          win
              ? 'Take "ffmpeg-release-essentials.zip"; ffmpeg.exe and ffprobe.exe are in its '
                  'bin folder. Put both in the tools folder.'
              : 'Every distribution has an ffmpeg package, and it includes ffprobe.',
        ),
      if (missing.contains('node or deno'))
        ToolLink(
          'Deno (or Node.js)',
          'yt-dlp needs a JavaScript runtime to read YouTube\'s player',
          win ? 'https://github.com/denoland/deno/releases/latest' : 'https://deno.com/',
          win
              ? 'Take "deno-x86_64-pc-windows-msvc.zip"; deno.exe is the one file in it. '
                  'Put it in the tools folder. Node.js from nodejs.org does as well.'
              : 'Either will do; nodejs is in every distribution.',
        ),
    ];
  }

  /// On a Mac, Homebrew is the plain way to have all three, and nobody is expected to
  /// fetch them by hand: a program downloaded in a browser is quarantined, and macOS
  /// then refuses to run it without a word to the app that tried.
  static List<ToolLink> _macLinks(List<String> missing) => [
        if (missing.isNotEmpty)
          ToolLink(
            'Homebrew',
            'installs all of them in one line',
            'https://brew.sh/',
            'Install Homebrew (one line, from its page, in Terminal), then: '
                '${howToInstall(missing)}. WetOwl finds them there by itself.',
          ),
      ];

  /// Where programs are put on a Mac, which an app opened from the Finder does not
  /// have on its PATH: it gets /usr/bin:/bin:/usr/sbin:/sbin and nothing else, so a
  /// perfectly good Homebrew was invisible to it. Homebrew on Apple silicon, then on
  /// Intel, then MacPorts, then deno's own installer.
  static List<String> macPlaces(Map<String, String> env) => [
        '/opt/homebrew/bin',
        '/usr/local/bin',
        '/opt/local/bin',
        if (env['HOME'] != null) '${env['HOME']}/.deno/bin',
      ];

  /// The PATH to search: the one this program was given, and on a Mac the places
  /// above after it.
  static List<String> searchPath({Map<String, String>? environment, bool? mac}) {
    final env = environment ?? Platform.environment;
    final dirs = (env['PATH'] ?? '')
        .split(Platform.isWindows ? ';' : ':')
        .where((d) => d.isNotEmpty)
        .toList();
    if (mac ?? Platform.isMacOS) {
      for (final d in macPlaces(env)) {
        if (!dirs.contains(d)) dirs.add(d);
      }
    }
    return dirs;
  }

  static Future<Tools> find({Directory? own}) async {
    Future<String?> where(String name) async {
      final exe = Platform.isWindows ? '$name.exe' : name;
      if (own != null) {
        final mine = File('${own.path}${Platform.pathSeparator}$exe');
        if (await mine.exists()) return mine.path;
      }
      for (final d in searchPath()) {
        final f = File('$d${Platform.pathSeparator}$exe');
        if (await f.exists()) return f.path;
      }
      return null;
    }

    final node = await where('node');
    final deno = node == null ? await where('deno') : null;
    return Tools(
      ytdlp: await where('yt-dlp'),
      ffmpeg: await where('ffmpeg'),
      ffprobe: await where('ffprobe'),
      js: node != null
          ? (name: 'node', path: node)
          : deno != null
              ? (name: 'deno', path: deno)
              : null,
    );
  }
}

/// One missing program: what it is for and where it comes from.
class ToolLink {
  const ToolLink(this.name, this.whatFor, this.url, this.note);
  final String name;
  final String whatFor;
  final String url;
  final String note;
}
