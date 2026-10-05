// This computer playing the phone: opens the door to a server (worker/exit_tunnel.dart)
// and keeps it open, saying what crosses it, and fetches the songs the server tells it
// to fetch itself (worker/door_pull.dart) into a folder of its own. For trying the
// server's half against a real YouTube without building an app — the house's yt-dlp
// asks its questions from this computer's address.
//
//   dart run tool/exit_spike/door.dart <server url> <token> [wifi|cellular] [mobile data: yes|no]
//       [pulls: yes|no] [folder]
import 'dart:async';
import 'dart:io';

import 'package:muse/src/worker/door_pull.dart';
import 'package:muse/src/worker/exit_tunnel.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: door.dart <server url> <token> [wifi|cellular] [yes|no] '
        '[pulls: yes|no] [folder]');
    exit(64);
  }
  final network = args.length > 2 ? args[2] : 'wifi';
  final data = args.length > 3 ? args[3] != 'no' : true;
  final pulls = args.length > 4 ? args[4] != 'no' : true;
  final folder = Directory(args.length > 5 ? args[5] : '${Directory.systemTemp.path}/door-pulled');
  void say(String line) =>
      stdout.writeln('${DateTime.now().toIso8601String().substring(11, 19)}  $line');
  final puller = DoorPuller(
    baseUrl: () => args[0],
    token: () => args[1],
    keepDir: () async => folder,
    onArrived: (track, path) => say('track $track is here: $path'),
    onSaid: say,
  );
  final door = ExitTunnel(
    url: () => exitUrlFor(args[0]),
    token: () => args[1],
    hello: () => {
      'network': network,
      'mobile_data': data,
      'platform': 'spike',
      if (pulls) 'pulls': 1,
    },
    onPull: (order) {
      final o = PullOrder.fromJson(order);
      if (o == null) return;
      say('told to fetch track ${o.track} myself (${o.bytes ?? '?'} bytes)');
      unawaited(puller.pull(o));
    },
  );
  var said = '';
  door.addListener(() {
    final now = '${door.state.name} streams=${door.streams} opened=${door.opened} '
        'bytes=${door.bytes}${door.problem == null ? '' : ' (${door.problem})'}';
    if (now == said) return;
    said = now;
    say(now);
  });
  await door.start();
  ProcessSignal.sigint.watch().listen((_) async {
    await door.stop();
    exit(0);
  });
}
