// Taking records apart on this computer — where there is a computer to do it.
//
// A browser has neither ffmpeg nor the cores to spare, so the half that does the work
// is only compiled where it can run. See render_parts_io.dart.
export 'render_parts_none.dart' if (dart.library.io) 'render_parts_io.dart';
