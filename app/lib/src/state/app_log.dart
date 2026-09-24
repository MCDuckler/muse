// The app's own log, kept in a file on a desk — what debugPrint says, and every
// error Flutter catches — so that a booth that froze or a mix that went wrong can be
// looked at afterwards. Nothing on the web.
export 'app_log_none.dart' if (dart.library.io) 'app_log_io.dart';
