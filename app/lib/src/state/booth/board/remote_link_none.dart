import 'remote_board.dart';

/// A browser page served over https cannot open a plain socket to a desk on the
/// local network: the relay is the only wire.
Future<RemoteLink?> connectLan(Map<String, dynamic> advert, {required String name}) async => null;

Future<RemoteLink?> connectLanUrl(String url, {required String name}) async => null;
