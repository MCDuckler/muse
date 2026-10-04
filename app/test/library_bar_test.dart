// The bar over the playlists: a name typed narrows the box to what is called that, the
// order and the look are remembered, a kind narrows further, and what the library
// cannot find by name is handed to the Search tab.
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
import 'package:muse/src/state/library_query.dart';
import 'package:muse/src/state/selection.dart';
import 'package:muse/src/ui/library_page.dart';
import 'package:muse/src/ui/search_page.dart' show searchAsked;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  Map<String, dynamic> list(int id, String name,
          {int? folder, bool pinned = false, String kind = 'local', String? opened,
          String? made, bool saved = false, Map<String, dynamic>? mix}) =>
      {
        'id': id,
        'name': name,
        'kind': kind,
        'items': 3,
        'folder_id': folder,
        'pinned': pinned,
        'last_opened_at': opened,
        'created_at': made,
        'saved': saved,
        'owner_name': saved ? 'pal' : null,
        'mix': mix,
      };

  final playlists = [
    list(9, 'Favourites', kind: 'favourites'),
    list(10, 'Dub', folder: 1, opened: '2026-10-01T10:00:00Z', made: '2026-01-01T00:00:00Z'),
    list(11, 'Disco', folder: 1, made: '2026-03-01T00:00:00Z'),
    list(12, 'Drive', pinned: true, kind: 'spotify', opened: '2026-10-03T10:00:00Z'),
    list(13, 'Loose one', made: '2026-09-01T00:00:00Z'),
    list(14, 'Theirs', saved: true),
    list(15, 'Saturday mix', mix: {'moves': []}, opened: '2026-10-02T10:00:00Z'),
  ];
  final folders = [
    {'id': 1, 'name': 'Nights', 'pos': 0, 'count': 2},
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    useThisClientInstead(MockClient((request) async {
      final Object body = switch ((request.method, request.url.path)) {
        ('GET', '/playlists') => playlists,
        ('GET', '/playlist-folders') => {'items': folders},
        ('GET', '/library/tracks') => {'items': [], 'total': 0},
        ('GET', '/library/albums') => {'items': [], 'total': 0},
        ('GET', '/library/artists') => {'items': [], 'total': 0},
        ('GET', '/feed') => {'items': [], 'unseen': 0, 'following': 0},
        ('GET', '/library/smart') => {'lists': []},
        _ => <String, dynamic>{},
      };
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    }));
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 'x');
    app.closedSections = {'contents', 'folder:1'};
  });

  tearDown(() => useThisClientInstead(http.Client()));

  Future<void> show(WidgetTester tester, {Size size = const Size(420, 1400)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await app.refreshPlaylists();
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => Selection()),
      ],
      child: MaterialApp(home: Scaffold(body: const LibraryPage())),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  List<Playlist> parsed() => [for (final j in playlists) Playlist.fromJson(j)];
  List<PlaylistFolder> dividers() => [for (final j in folders) PlaylistFolder.fromJson(j)];

  test('the orders: recently opened first, newest made, A to Z, by source, by hand', () {
    List<String> looseIn(LibrarySort sort) => [
          for (final p in LibraryQuery(playlists: parsed(), folders: dividers(), sort: sort).loose)
            p.name
        ];
    expect(looseIn(LibrarySort.recent), ['Favourites', 'Saturday mix', 'Loose one', 'Theirs'],
        reason: 'the heart first, then by when opened, the never-opened last by name');
    expect(looseIn(LibrarySort.added), ['Favourites', 'Loose one', 'Saturday mix', 'Theirs']);
    expect(looseIn(LibrarySort.name), ['Favourites', 'Loose one', 'Saturday mix', 'Theirs']);
    expect(looseIn(LibrarySort.source), ['Favourites', 'Loose one', 'Saturday mix', 'Theirs'],
        reason: 'somebody else\'s list comes after everything of your own');
    final q = LibraryQuery(playlists: parsed(), folders: dividers());
    expect(q.recent.map((p) => p.name), ['Drive', 'Saturday mix', 'Dub']);
    expect(q.chips, [LibraryChip.all, LibraryChip.mine, LibraryChip.mirrors,
        LibraryChip.others, LibraryChip.mixes]);
  });

  test('a kind narrows the box; words typed flatten it', () {
    final mirrors = LibraryQuery(playlists: parsed(), folders: dividers(), chip: LibraryChip.mirrors);
    expect(mirrors.pinned.map((p) => p.name), ['Drive']);
    expect(mirrors.loose, isEmpty);
    expect(mirrors.shelves.single.playlists, isEmpty);
    expect(mirrors.nothing, isFalse);

    final typed = LibraryQuery(playlists: parsed(), folders: dividers(), query: 'd');
    expect(typed.matches.map((p) => p.name), ['Drive', 'Saturday mix', 'Dub', 'Disco'],
        reason: 'in the order asked for, whichever divider they are behind');
    expect(typed.matchedFolders, isEmpty);
    expect(typed.folderOf(typed.matches[2])?.name, 'Nights');
    final folder = LibraryQuery(playlists: parsed(), folders: dividers(), query: 'nigh');
    expect(folder.matchedFolders.single.folder.name, 'Nights');
    expect(folder.matches, isEmpty);
    expect(folder.nothing, isFalse);
  });

  testWidgets('typing narrows the page, and Enter hands the rest to Search', (tester) async {
    await show(tester);
    expect(find.text('NIGHTS'), findsOneWidget);
    expect(find.text('Loose one'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'dis');
    await tester.pumpAndSettle();
    expect(find.text('Disco'), findsOneWidget, reason: 'found behind its closed divider');
    expect(find.text('in Nights · 3 tracks'), findsOneWidget);
    expect(find.text('Loose one'), findsNothing);
    expect(find.text('NIGHTS'), findsNothing, reason: 'the dividers come out while searching');
    expect(find.textContaining('Search songs, records and artists for'), findsOneWidget);

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(searchAsked.value, (query: 'dis', where: 'library'));
    expect(app.homeTab, Tabs.search);
    searchAsked.value = null;
  });

  testWidgets('the order, the look and the kind are remembered', (tester) async {
    await show(tester);
    await tester.tap(find.byTooltip('Order · Recently opened'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A to Z'));
    await tester.pumpAndSettle();
    expect(app.librarySort, LibrarySort.name);
    expect(find.text('OPENED LATELY'), findsOneWidget,
        reason: 'in another order, what was opened lately gets a strip of its own');

    await tester.tap(find.text('MIRRORS'));
    await tester.pumpAndSettle();
    expect(find.text('Drive'), findsWidgets);
    expect(find.text('Loose one'), findsNothing);
    await tester.tap(find.text('ALL'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Look'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Covers'));
    await tester.pumpAndSettle();
    expect(app.libraryLook, LibraryLook.grid);
    expect(find.text('FOLDER'), findsOneWidget, reason: 'a folder is a card among the covers');
    expect(find.byType(PlaylistRow), findsNothing, reason: 'no rows in a wall of covers');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('muse.library.sort'), 'name');
    expect(prefs.getString('muse.library.look'), 'grid');
  });

  testWidgets('in the hand order the rows get handles, and a drag writes the shelf whole',
      (tester) async {
    final ordered = <http.Request>[];
    useThisClientInstead(MockClient((request) async {
      if (request.url.path == '/playlists/order') ordered.add(request);
      final Object body = switch ((request.method, request.url.path)) {
        ('GET', '/playlists') => playlists,
        ('GET', '/playlist-folders') => {'items': folders},
        ('GET', '/library/smart') => {'lists': []},
        ('GET', '/feed') => {'items': [], 'unseen': 0, 'following': 0},
        _ => <String, dynamic>{},
      };
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    }));
    app.librarySort = LibrarySort.hand;
    await show(tester);
    expect(find.byIcon(Icons.drag_indicator), findsWidgets);

    // Nothing has a place yet, so the box reads Favourites, Loose one, Saturday mix,
    // Theirs; only the loose rows carry handles. Drag Theirs to the top.
    expect(find.byIcon(Icons.drag_indicator), findsNWidgets(4));
    final from = tester.getCenter(find.byIcon(Icons.drag_indicator).at(3));
    final to = tester.getCenter(find.text('Favourites'));
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(to - const Offset(0, 20));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(ordered, isNotEmpty);
    final body = jsonDecode(ordered.last.body);
    expect(body['folder_id'], isNull);
    final ids = (body['ids'] as List).cast<int>();
    expect(ids.length, 4, reason: 'the whole shelf is written, not one position');
    expect(ids.indexOf(14), lessThan(ids.indexOf(13)), reason: 'Theirs moved above Loose one');
  });
}
