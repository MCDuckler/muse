// This phone opening the door to YouTube for the house — where it is a phone.
//
// A computer fetches with programs of its own (this_computer.dart). A phone can't run
// them and doesn't need to: the server asks YouTube through it (exit_tunnel.dart).
// A browser can't open the connections, so it gets nothing.
export 'door_here_none.dart' if (dart.library.io) 'door_here_io.dart';
