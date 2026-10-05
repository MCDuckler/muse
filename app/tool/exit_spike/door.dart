// This computer playing the phone: opens the door to a server (worker/exit_tunnel.dart)
// and keeps it open, saying what crosses it. For trying the server's half against a real
// YouTube without building an app — the house's yt-dlp asks its questions from this
// computer's address.
//
//   dart run tool/exit_spike/door.dart <server url> <token> [wifi|cellular] [mobile data: yes|no]
import 'dart:async';
import 'dart:io';

import 'package:muse/src/worker/exit_tunnel.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: door.dart <server url> <token> [wifi|cellular] [yes|no]');
    exit(64);
  }
  final network = args.length > 2 ? args[2] : 'wifi';
  final data = args.length > 3 ? args[3] != 'no' : true;
  final door = ExitTunnel(
    url: () => exitUrlFor(args[0]),
    token: () => args[1],
    hello: () => {'network': network, 'mobile_data': data, 'platform': 'spike'},
  );
  var said = '';
  door.addListener(() {
    final now = '${door.state.name} streams=${door.streams} opened=${door.opened} '
        'bytes=${door.bytes}${door.problem == null ? '' : ' (${door.problem})'}';
    if (now == said) return;
    said = now;
    stdout.writeln('${DateTime.now().toIso8601String().substring(11, 19)}  $now');
  });
  await door.start();
  ProcessSignal.sigint.watch().listen((_) async {
    await door.stop();
    exit(0);
  });
}
