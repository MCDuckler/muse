// The "where it plays" sheet, with a few devices in every state, to be looked at.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/devices_sheet.dart';
import 'package:muse/src/ui/theme.dart';

DeviceInfo d(int id, String name, String kind, {bool this_ = false, bool live = true, bool playing = false, Track? track, int daysAgo = 0}) =>
    DeviceInfo(id: id, name: name, kind: kind, isThis: this_, live: live, playing: playing, track: track,
        queue: 'Late night', queueId: 1, lastSeen: DateTime.now().subtract(Duration(days: daysAgo, minutes: 3)));

void main() {
  final dark = Uri.base.queryParameters['theme'] == 'dark';
  final track = Track.fromJson({'id': 2, 'title': 'Everything In Its Right Place', 'artists': ['Radiohead'], 'album': 'Kid A', 'state': 'ready', 'stream_url': '/s', 'source': 'youtube', 'cover_color': '#c2571a'});
  final app = AppState()..api = (ApiClient(baseUrl: 'http://127.0.0.1:9')..token = 'x');
  app.thisDevice = 1;
  app.devices = [
    d(1, 'Firefox on Linux', 'browser', this_: true),
    d(2, 'Kitchen', 'phone', playing: true, track: track),
    d(3, 'chris-laptop', 'desktop', track: track),
    d(4, 'iPad', 'tablet'),
    d(5, 'flutter', 'browser', live: false, daysAgo: 4),
    d(6, 'flutter', 'phone', live: false, daysAgo: 12),
  ];
  app.playingOn = 2;
  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider(create: (_) => Selection()),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: dark ? MuseTheme.dark() : MuseTheme.light(),
      home: Builder(builder: (context) {
        WidgetsBinding.instance.addPostFrameCallback((_) => showDevices(context));
        return const Scaffold(body: Center(child: WhereItPlays()));
      }),
    ),
  ));
}
