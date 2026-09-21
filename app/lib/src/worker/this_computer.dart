// This computer fetching music for the house — where there is a computer to do it.
//
// A browser cannot run yt-dlp; everything else can in principle, and a desk actually
// does. The half that runs programs is only compiled where programs can be run.
export 'this_computer_none.dart' if (dart.library.io) 'this_computer_io.dart';
