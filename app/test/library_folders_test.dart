// Folders: the divider cards in the record box. The library arranges its playlists
// by them, a playlist moves between them from its menu, and the add-to-playlist sheet
// reads the same arrangement.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/connection.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/state/library_arrangement.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/folders.dart';
import 'package:muse/src/ui/library_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late List<http.Request> asked;
  late List<Map<String, dynamic>> playlists;
  late List<Map<String, dynamic>> folders;

  Map<String, dynamic> list(int id, String name,
          {int? folder, bool pinned = false, int? pos, String kind = 'local'}) =>
      {
        'id': id,
        'name': name,
        'kind': kind,
        'items': 3,
        'folder_id': folder,
        'place_pos': pos,
        'pinned': pinned,
      };

  setUp(() {
    asked = [];
    folders = [
      {'id': 1, 'name': 'Nights', 'pos': 0, 'count': 2},
      {'id': 2, 'name': 'Empty box', 'pos': 1, 'count': 0},
    ];
    playlists = [
      list(9, 'Favourites', kind: 'favourites'),
      list(10, 'Dub', folder: 1, pos: 1),
      list(11, 'Disco', folder: 1, pos: 0),
      list(12, 'Drive', pinned: true),
      list(13, 'Loose one'),
    ];
    SharedPreferences.setMockInitialValues({});
    useThisClientInstead(MockClient((request) async {
      asked.add(request);
      final Object body = switch ((request.method, request.url.path)) {
        ('GET', '/playlists') => playlists,
        ('GET', '/playlist-folders') => {'items': folders},
        ('GET', '/library/tracks') => {'items': [], 'total': 0},
        ('GET', '/library/albums') => {'items': [], 'total': 0},
        ('GET', '/library/artists') => {'items': [], 'total': 0},
        ('GET', '/feed') => {'items': [], 'unseen': 0, 'following': 0},
        ('GET', '/library/smart') => {'lists': []},
        ('GET', '/linked') => {'accounts': []},
        ('GET', '/spotify/account') => {'configured': false},
        ('POST', '/playlists/13/place') => {'playlist_id': 13, 'folder_id': 1, 'pos': 2},
        ('POST', '/playlists/13/pin') => {'playlist_id': 13, 'pinned': true},
        ('POST', '/playlist-folders') => {'id': 3, 'name': 'Fresh', 'pos': 2, 'count': 0},
        _ => <String, dynamic>{},
      };
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
  });

  tearDown(() => useThisClientInstead(http.Client()));

  Future<void> show(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await app.refreshPlaylists();
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(home: Scaffold(body: page)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  test('the arrangement: pinned, then folders in filed order, then the rest', () {
    final arranged = LibraryArrangement(
        [for (final j in playlists) Playlist.fromJson(j)],
        [for (final j in folders) PlaylistFolder.fromJson(j)]);
    expect(arranged.pinned.map((p) => p.name), ['Drive']);
    expect(arranged.shelves.map((s) => s.folder.name), ['Nights', 'Empty box']);
    expect(arranged.shelves.first.playlists.map((p) => p.name), ['Disco', 'Dub'],
        reason: 'in the order they were filed, not the order they came');
    expect(arranged.loose.map((p) => p.name), ['Favourites', 'Drive', 'Loose one'],
        reason: 'a pinned list is also where it was, so nothing is lost on unpinning');
    expect(arranged.flat, isFalse);

    // A folder the server no longer lists leaves its playlists loose, not nowhere.
    final orphaned = LibraryArrangement(
        [Playlist.fromJson(list(1, 'Stray', folder: 99))], const []);
    expect(orphaned.loose.map((p) => p.name), ['Stray']);
    expect(orphaned.flat, isTrue);
  });

  testWidgets('the library shows divider cards, and a card opens on its lists',
      (tester) async {
    app.closedSections = {'contents', 'folder:1'};
    await show(tester, const LibraryPage());
    expect(find.text('PINNED'), findsOneWidget);
    expect(find.text('NIGHTS'), findsOneWidget);
    expect(find.text('EMPTY BOX'), findsOneWidget);
    expect(find.text('EVERYTHING ELSE'), findsOneWidget);
    expect(find.text('Disco'), findsNothing, reason: 'the card is closed');
    expect(find.text('Loose one'), findsOneWidget);
    expect(find.text('Drive'), findsOneWidget);

    await tester.tap(find.text('NIGHTS'));
    await tester.pumpAndSettle();
    expect(find.text('Disco'), findsOneWidget);
    expect(find.text('Dub'), findsOneWidget);
    expect(app.closedSections, isNot(contains('folder:1')));
  });

  testWidgets('a playlist is moved into a folder from its menu', (tester) async {
    app.closedSections = {'contents', 'folder:1', 'folder:2'};
    await show(tester, const LibraryPage());

    await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'Loose one'),
        matching: find.byIcon(Icons.more_vert)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to a folder…'));
    await tester.pumpAndSettle();
    expect(find.text('New folder…'), findsOneWidget);
    expect(find.text('Nights'), findsOneWidget);

    // The server files it; the next listing says so.
    playlists = [
      for (final j in playlists)
        if (j['id'] == 13) {...j, 'folder_id': 1, 'place_pos': 2} else j
    ];
    await tester.tap(find.text('Nights'));
    await tester.pumpAndSettle();
    final place = asked.lastWhere((r) => r.url.path == '/playlists/13/place');
    expect(jsonDecode(place.body)['folder_id'], 1);
    expect(find.text('"Loose one" is in "Nights"'), findsOneWidget);
    expect(app.closedSections, isNot(contains('folder:1')),
        reason: 'the folder it went into opens to show it arrived');
    expect(find.text('Loose one'), findsOneWidget,
        reason: 'behind the divider now, which opened to show it');
    expect(find.text('Favourites'), findsOneWidget,
        reason: 'still loose: the heart is never filed');
  });

  testWidgets('New offers a folder as well as a playlist', (tester) async {
    app.closedSections = {'contents'};
    await show(tester, const LibraryPage());
    await tester.tap(find.text('NEW'));
    await tester.pumpAndSettle();
    expect(find.text('New playlist…'), findsOneWidget);
    expect(find.text('New folder…'), findsOneWidget);
    await tester.tap(find.text('New folder…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Fresh');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final made = asked.lastWhere((r) => r.url.path == '/playlist-folders' && r.method == 'POST');
    expect(jsonDecode(made.body)['name'], 'Fresh');
  });

  testWidgets('a folder opened as a page lists what is in it', (tester) async {
    await show(tester, const FolderPage(folderId: 1));
    expect(find.text('Nights'), findsOneWidget);
    expect(find.text('2 PLAYLISTS'), findsOneWidget);
    expect(find.text('Disco'), findsOneWidget);
    expect(find.text('Dub'), findsOneWidget);
    expect(find.text('Loose one'), findsNothing);
  });
}
