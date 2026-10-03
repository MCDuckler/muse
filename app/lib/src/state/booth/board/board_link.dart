// The link's desk end, for whichever platform this is.
export 'link_server.dart';

import 'link_server_none.dart' if (dart.library.io) 'link_server_io.dart' as platform;
import '../booth.dart';
import 'link_server.dart';

BoardLinkBase boardLinkForThisDevice({required Booth Function() booth}) => platform.boardLink(booth: booth);
