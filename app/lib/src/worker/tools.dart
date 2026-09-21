import 'dart:io';

/// The programs the downloader runs, and where they are.
///
/// yt-dlp to fetch, ffmpeg and ffprobe to look at and (rarely) convert what it fetched,
/// and a JavaScript runtime because yt-dlp needs one to read YouTube's player. Looked
/// for first in the app's own tools folder, then on the PATH — on Linux they are nearly
/// always a package away and the distribution's copy is the one that gets security
/// fixes. What is missing is named, with what to do about it.
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
    return 'pacman -S $wanted   ·   apt install $wanted   ·   dnf install $wanted';
  }

  static Future<Tools> find({Directory? own}) async {
    Future<String?> where(String name) async {
      final exe = Platform.isWindows ? '$name.exe' : name;
      if (own != null) {
        final mine = File('${own.path}${Platform.pathSeparator}$exe');
        if (await mine.exists()) return mine.path;
      }
      final dirs = (Platform.environment['PATH'] ?? '')
          .split(Platform.isWindows ? ';' : ':')
          .where((d) => d.isNotEmpty);
      for (final d in dirs) {
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
