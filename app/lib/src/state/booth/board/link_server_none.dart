import '../booth.dart';
import 'link_server.dart';

/// A browser cannot listen: screens reach this booth's board through the relay only.
BoardLinkBase boardLink({required Booth Function() booth}) => BoardLinkBase(booth: booth);
