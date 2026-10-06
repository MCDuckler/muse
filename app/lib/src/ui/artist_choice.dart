import 'package:flutter/material.dart';

import '../api/models.dart';
import 'browse_page.dart' show ArtistPage;
import 'widths.dart';

/// Who a song is by, as names to open. None when nobody is named: its line then reads
/// "Unknown artist", which is not somebody with a page.
List<String> artistsOf(Track track) => track.artists;

/// The artist of a song, opened — or, when it is by several, which of them first.
///
/// "Go to the artist" used to mean the first name on the credit, so a song by
/// Bicep and Clara La San only ever led to Bicep. With [anchor], the choice is a menu
/// beside what was tapped; without one, a sheet.
Future<void> openArtistOf(BuildContext context, Track track, {BuildContext? anchor}) async {
  final names = artistsOf(track);
  if (names.isEmpty) return;
  final navigator = Navigator.of(context);
  final name = names.length == 1 ? names.single : await chooseArtist(anchor ?? context, names, menu: anchor != null);
  if (name == null) return;
  navigator.push(MaterialPageRoute(
      builder: (_) => ArtistPage(artist: ArtistSummary(name: name, tracks: 0))));
}

/// One of [names], chosen: a menu at [context]'s widget when [menu], else a sheet (a
/// dialog at a desk).
Future<String?> chooseArtist(BuildContext context, List<String> names, {bool menu = true}) {
  final box = context.findRenderObject();
  final overlay = Navigator.of(context).overlay?.context.findRenderObject();
  if (menu && box is RenderBox && box.hasSize && overlay is RenderBox) {
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final position = RelativeRect.fromRect(
        Rect.fromPoints(topLeft, topLeft + box.size.bottomRight(Offset.zero)),
        Offset.zero & overlay.size);
    return showMenu<String>(
      context: context,
      position: position,
      items: [
        for (final n in names)
          PopupMenuItem(
            value: n,
            child: Row(children: [
              const Icon(Icons.person_outline, size: 20),
              const SizedBox(width: 12),
              Flexible(child: Text(n, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
          ),
      ],
    );
  }
  return ask<String>(
    context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text('Which artist?', style: Theme.of(sheet).textTheme.titleMedium),
          ),
          for (final n in names)
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(n, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.of(sheet).pop(n),
            ),
        ],
      ),
    ),
  );
}
