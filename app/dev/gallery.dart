// The song row in every state it can be in, on one page, to be looked at.
//
// Not shipped: `flutter build web -t dev/gallery.dart -o build/gallery`, serve the
// folder and open it — `?theme=dark` for the late edition. A row is judged by eye,
// and the states that matter most (playing, on its way, being pushed) are the ones
// that need a running player or a finger on the screen to reach in the real app.
import 'package:flutter/material.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/player.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/found_row.dart';
import 'package:muse/src/ui/mag_parts.dart';
import 'package:muse/src/ui/song_row.dart';
import 'package:muse/src/ui/swipe.dart';
import 'package:muse/src/ui/theme.dart';

import '../test/fake_audio.dart';

Track song(int id, String title, String artist,
        {String? album,
        String state = 'ready',
        String source = 'youtube',
        String? colour,
        Map<String, dynamic>? progress,
        String? failReason,
        int seconds = 214}) =>
    Track.fromJson({
      'id': id,
      'title': title,
      'artists': [artist],
      if (album != null) 'album': album,
      'duration_ms': seconds * 1000,
      'state': state,
      if (state == 'ready') 'stream_url': '/tracks/$id/stream',
      'source': source,
      if (colour != null) 'cover_color': colour,
      if (progress != null) 'progress': progress,
      if (failReason != null) 'fail_reason': failReason,
    });

/// An app of its own for each block, so each can have its own idea of what is playing.
Widget block(String flag, PlayingNow now, Widget Function(BuildContext) body,
    {void Function(Selection)? pick}) {
  final app = AppState()
    ..api = (ApiClient(baseUrl: 'http://127.0.0.1:9')..token = 'x');
  app.player = PlayerService(app.api)..playingNow.value = now;
  final selection = Selection();
  pick?.call(selection);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<Selection>.value(value: selection),
    ],
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 18, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 8),
            child: SectionFlag(flag),
          ),
          Builder(builder: body),
        ],
      ),
    ),
  );
}

const rest = (trackId: null, itemId: null, playing: false, buffering: false);

void main() {
  JustAudioPlatform.instance = FakeJustAudio();
  final dark = Uri.base.queryParameters['theme'] == 'dark';
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: dark ? MuseTheme.dark() : MuseTheme.light(),
    home: Scaffold(
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          block('Plain, and where they came from', rest, (context) => Column(children: [
                SongRow(track: song(1, 'Get Lucky', 'Daft Punk', album: 'Random Access Memories'), onTap: () {}),
                SongRow(track: song(2, 'Flim', 'Aphex Twin', album: 'Come to Daddy', source: 'bandcamp'), onTap: () {}),
                SongRow(track: song(3, 'Night Drive (Edit)', 'Somebody Local', source: 'soundcloud'), onTap: () {}),
                SongRow(track: song(4, 'Kitchen Demo 3', 'Me', source: 'custom', seconds: 3720), onTap: () {}),
              ])),
          block('Playing', (trackId: 12, itemId: null, playing: true, buffering: false), (context) => Column(children: [
                SongRow(track: song(11, 'HUMBLE.', 'Kendrick Lamar', album: 'DAMN.', colour: '#2a6f97'), onTap: () {}),
                SongRow(track: song(12, 'Everything In Its Right Place', 'Radiohead', album: 'Kid A', colour: '#c2571a'), onTap: () {}),
                SongRow(track: song(13, 'Teardrop', 'Massive Attack', album: 'Mezzanine', colour: '#3b3b3b'), onTap: () {}),
              ])),
          block('Paused', (trackId: 22, itemId: null, playing: false, buffering: false), (context) => Column(children: [
                SongRow(track: song(21, 'Redbone', 'Childish Gambino', colour: '#8a1c1c'), onTap: () {}),
                SongRow(track: song(22, 'Nightcall', 'Kavinsky', album: 'OutRun', colour: '#7b2cbf'), onTap: () {}),
              ])),
          block('Buffering', (trackId: 32, itemId: null, playing: true, buffering: true), (context) => Column(children: [
                SongRow(track: song(32, 'Midnight City', 'M83', colour: '#1b7f79'), onTap: () {}),
              ])),
          block('On its way, not here, failed', rest, (context) => Column(children: [
                SongRow(track: song(41, 'Hyperballad', 'Björk', state: 'downloading', progress: {'label': 'Fetching', 'percent': 0.42, 'speed': '1.1 MB/s'}), onTap: () {}),
                SongRow(track: song(42, 'Windowlicker', 'Aphex Twin', state: 'pending', progress: {'label': 'Looking it up'}), onTap: () {}),
                SongRow(track: song(43, 'Alright', 'Kendrick Lamar', album: 'To Pimp a Butterfly', state: 'pending'), onTap: () {}),
                SongRow(track: song(44, 'Some Rare Bootleg', 'Nobody', state: 'failed', failReason: 'Video unavailable'), onTap: () {}),
              ])),
          block('Picked out', rest, pick: (s) { s.start('gallery', 52); s.toggle('gallery', 53); }, (context) => Column(children: [
                SongRow(track: song(51, 'Genesis', 'Grimes', album: 'Visions'), selectable: 'gallery', onTap: () {}),
                SongRow(track: song(52, 'Oblivion', 'Grimes', album: 'Visions'), selectable: 'gallery', onTap: () {}),
                SongRow(track: song(53, 'Circumambient', 'Grimes', album: 'Visions'), selectable: 'gallery', onTap: () {}),
              ])),
          block('Being pushed', rest, (context) {
            Widget pushed(double by, {bool away = false, required Track t}) => SwipingNow(
                  progress: (by / 84).clamp(0.0, 1.0),
                  child: Stack(children: [
                    Positioned.fill(
                      child: SwipeBack(
                        away: away,
                        icon: away ? Icons.delete_outline : Icons.playlist_play,
                        label: away ? 'Remove' : 'Play next',
                      ),
                    ),
                    Transform.translate(
                      offset: Offset(away ? -by : by, 0),
                      child: SongRow(track: t, onTap: () {}, swipeToPlayNext: false),
                    ),
                  ]),
                );
            return Column(children: [
              pushed(28, t: song(61, 'Pushed a little', 'Not yet caught')),
              const SizedBox(height: 6),
              pushed(70, t: song(62, 'Pushed far enough', 'Caught: play next')),
              const SizedBox(height: 6),
              pushed(70, away: true, t: song(63, 'Pushed away', 'Caught: remove')),
            ]);
          }),
          block('A search: one list', rest, (context) {
            Found f(String kind, String place, String title, String sub, {Track? track, String? lyric}) => Found(
                kind: kind, place: place, id: '$title/$place', title: title, subtitle: sub,
                durationMs: 214000, track: track, lyric: lyric, known: place == 'library');
            return Column(children: [
              FoundRow(found: f('song', 'library', 'Get Lucky', 'Daft Punk', track: song(81, 'Get Lucky', 'Daft Punk', album: 'Random Access Memories')), onTap: () {}),
              FoundRow(found: f('song', 'ytmusic', 'Get Lucky (Radio Edit)', 'Daft Punk', lyric: 'we\'re up all night to get lucky'), onTap: () {}, onAdd: () {}, onMore: () {}),
              FoundRow(found: f('song', 'spotify', 'Get Lucky', 'Daft Punk, Pharrell Williams'), onTap: () {}, onAdd: () {}, onMore: () {}),
              FoundRow(found: f('video', 'youtube', 'Daft Punk - Get Lucky (Official Video)', 'DaftPunkVEVO'), onTap: () {}, onAdd: () {}, onMore: () {}),
              FoundRow(found: f('album', 'ytmusic', 'Random Access Memories', 'Daft Punk'), onTap: () {}, onMore: () {}),
              FoundRow(found: f('artist', 'ytmusic', 'Daft Punk', 'Artist'), onTap: () {}, onMore: () {}),
            ]);
          }),
          block('In the queue, dense, with a grip', (trackId: 72, itemId: null, playing: true, buffering: false), (context) {
            Widget grip() => Padding(
                  padding: const EdgeInsets.only(left: 2, right: 2),
                  child: Icon(Icons.drag_indicator, size: 18, color: Theme.of(context).colorScheme.outline),
                );
            return Column(children: [
              SongRow(track: song(71, 'Around the World', 'Daft Punk'), dense: true, handle: grip(), swipeToPlayNext: false, onTap: () {}),
              SongRow(track: song(72, 'Digital Love', 'Daft Punk', colour: '#d4a017'), dense: true, handle: grip(), swipeToPlayNext: false, onTap: () {}),
              SongRow(track: song(73, 'Something About Us', 'Daft Punk'), dense: true, handle: grip(), swipeToPlayNext: false, onTap: () {}),
            ]);
          }),
          const SizedBox(height: 40),
        ],
      ),
    ),
  ));
}
