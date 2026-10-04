// The library as a car sees it: a tree of things to play, a search, and the heart
// beside play and pause.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/car.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late CarBrowser car;
  late List<http.Request> asked;

  Map<String, dynamic> track(int id, String title) => {
        'id': id, 'title': title, 'artists': ['Someone'], 'album': 'A Record',
        'duration_ms': 200000, 'state': 'ready', 'cover_url': '/tracks/$id/cover',
      };

  final playlists = [
    {'id': 9, 'name': 'Favourites', 'kind': 'favourites', 'items': 4,
     'cover_url': '/playlists/9/cover', 'cover_version': 'aa'},
    {'id': 10, 'name': 'Dub', 'kind': 'local', 'items': 3, 'folder_id': 1,
     'cover_url': '/playlists/10/cover', 'cover_version': 'bb'},
    {'id': 12, 'name': 'Drive', 'kind': 'spotify', 'items': 40, 'pinned': true,
     'cover_url': '/playlists/12/cover', 'cover_version': 'cc',
     'last_opened_at': '2026-10-03T10:00:00Z'},
    {'id': 13, 'name': 'Loose one', 'kind': 'local', 'items': 2,
     'cover_url': '/playlists/13/cover', 'cover_version': 'dd'},
  ];

  setUp(() async {
    asked = [];
    useThisClientInstead(MockClient((request) async {
      asked.add(request);
      final Object body = switch ((request.method, request.url.path)) {
        ('GET', '/playlists') => playlists,
        ('GET', '/playlist-folders') => {'items': [{'id': 1, 'name': 'Nights', 'pos': 0, 'count': 1}]},
        ('GET', '/library/smart') => {'lists': [
            {'id': 'never', 'name': 'Never played', 'blurb': 'Not yet', 'count': 12},
            {'id': 'once', 'name': 'Played once', 'blurb': 'Once', 'count': 0},
          ]},
        ('GET', '/library/albums') => {'items': [
            {'name': 'Low', 'artist': 'Bowie', 'tracks': 11, 'cover_url': '/tracks/5/cover'},
          ], 'total': 1},
        ('GET', '/library/artists') => {'items': [
            {'name': 'Bowie', 'tracks': 30, 'albums': 3, 'cover_url': '/tracks/5/cover'},
          ], 'total': 1},
        ('GET', '/playlists/10') => {'id': 10, 'name': 'Dub', 'kind': 'local',
            'items': [track(1, 'King Tubby Meets'), track(2, 'Dub Fire')]},
        ('GET', '/search') => {'local': [track(3, 'Night Drive')], 'remote': []},
        ('GET', '/favourites') => {'playlist_id': 9, 'track_ids': [1, 3]},
        ('GET', '/queues') => <Object>[],
        ('POST', '/favourites/2') => {'favourite': true},
        _ => <String, dynamic>{},
      };
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
    await app.refreshPlaylists();
    await app.refreshFavourites();
    car = CarBrowser(app);
  });

  tearDown(() {
    car.dispose();
    useThisClientInstead(http.Client());
  });

  test('the root is four shelves, the records as a wall of covers', () async {
    final root = await car.getChildren(CarBrowser.root);
    expect(root.map((m) => m.id), ['home', 'playlists', 'records', 'artists']);
    expect(root.every((m) => m.playable == false), isTrue);
    expect(root[2].extras?['android.media.browse.CONTENT_STYLE_PLAYABLE_HINT'], 2);
  });

  test('the box: pinned, folders to open, the rest to play, every face a signed URL',
      () async {
    final items = await car.getChildren(CarBrowser.playlists);
    expect(items.map((m) => m.id), ['playlist:12', 'folder:1', 'playlist:9', 'playlist:13']);
    expect(items[0].playable, isTrue);
    expect(items[0].extras?['android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT'], 'Pinned');
    expect(items[0].displaySubtitle, 'Spotify · 40 songs');
    expect(items[1].playable, isFalse, reason: 'a folder opens');
    expect(items[0].artUri.toString(), startsWith('http://example.invalid/playlists/12/cover'));

    final folder = await car.getChildren('folder:1');
    expect(folder.map((m) => m.title), ['Dub']);
    final songs = await car.getChildren('playlist:10');
    expect(songs.map((m) => m.id), ['track:1', 'track:2']);
    expect(songs.first.artist, 'Someone');
  });

  test('home: the heart, what was opened lately, the lists that fill themselves in',
      () async {
    final home = await car.getChildren(CarBrowser.home);
    final ids = home.map((m) => m.id).toList();
    expect(ids, contains('playlist:12'), reason: 'opened lately');
    expect(ids, contains('favourites'));
    expect(ids, contains('smart:never'));
    expect(ids, isNot(contains('smart:once')), reason: 'empty, so left off');
    expect(home.firstWhere((m) => m.id == 'favourites').displaySubtitle, '4 songs you hearted');
  });

  test('records and artists come from the library, an artist opens on their records',
      () async {
    final records = await car.getChildren(CarBrowser.records);
    expect(records.single.id, 'album:Low\u0001Bowie');
    expect(records.single.playable, isTrue);
    final artists = await car.getChildren(CarBrowser.artists);
    expect(artists.single.id, 'artist:Bowie');
    final bowie = await car.getChildren('artist:Bowie');
    expect(bowie.first.id, 'artist-all:Bowie');
    expect(bowie.map((m) => m.title), ['Everything by Bowie', 'Low']);
  });

  test('a search answers with playlists, records and songs', () async {
    final found = await car.search('dri');
    expect(found.map((m) => m.id), ['playlist:12', 'album:Low\u0001Bowie', 'track:3']);
  });

  test('a tap on a playlist asks for its songs and plays them', () async {
    try {
      await car.playFromMediaId('playlist:10');
    } catch (_) {
      // There is no engine and no queue on the server here; the ask is the point.
    }
    expect(asked.any((r) => r.url.path == '/playlists/10'), isTrue);
    expect(asked.any((r) => r.method == 'POST' && r.url.path.startsWith('/queues')), isTrue,
        reason: 'the songs went towards a queue');
  });

  test('the heart beside play follows the song, and pressing it hearts the song',
      () async {
    expect(car.extraControls(), isEmpty, reason: 'nothing playing, nothing to heart');

    var now = Track.fromJson(track(1, 'King Tubby Meets'));
    car.nowPlaying = () => now;
    var heart = car.extraControls().first;
    expect(heart.androidIcon, 'drawable/ic_media_heart', reason: 'already hearted');
    expect(heart.customAction?.name, CarBrowser.heartAction);

    now = Track.fromJson(track(2, 'Dub Fire'));
    heart = car.extraControls().first;
    expect(heart.androidIcon, 'drawable/ic_media_heart_outline');

    await car.customAction(CarBrowser.heartAction, {'track': 2});
    expect(asked.any((r) => r.method == 'POST' && r.url.path == '/favourites/2'), isTrue);
    expect(app.isFavourite(2), isTrue);
    expect(car.extraControls().first.androidIcon, 'drawable/ic_media_heart');
    expect(car.extraControls().map((c) => c.customAction?.name),
        [CarBrowser.heartAction, CarBrowser.shuffleAction]);
  });

  test('repeat is the queue\'s repeat', () {
    expect(car.repeatMode, AudioServiceRepeatMode.none);
  });
}
