import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'dialogs.dart';
import 'feed_page.dart' show BandcampRecordPage;
import 'mag.dart';
import 'mag_parts.dart';
import 'mini_player.dart';
import 'skeleton.dart';
import 'sleeve_art.dart';
import 'snack.dart';
import 'widths.dart';

/// An act's own few words about themselves, in a sheet, with where they came from.
///
/// Asked for from where their music came from first — the Bandcamp page's bio, the
/// SoundCloud profile — and YouTube Music after; [bandcamp] names a page outright.
Future<void> showAbout(BuildContext context, String name, {String? bandcamp, String? text}) async {
  final api = context.read<AppState>().api;
  final messenger = ScaffoldMessenger.of(context);
  ArtistAbout about;
  if (text != null && text.isNotEmpty) {
    about = ArtistAbout(name: name, text: text, source: 'bandcamp', url: bandcamp);
  } else {
    try {
      about = await api.artistAbout(name, bandcamp: bandcamp);
    } catch (e) {
      messenger.say(problem(e));
      return;
    }
  }
  if (!context.mounted) return;
  if ((about.text ?? '').isEmpty) {
    messenger.say(snack(Text('Nobody has written anything about $name yet')));
    return;
  }
  await ask<void>(
    context,
    scrollable: true,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Kicker('About'),
            Text(name.toUpperCase(),
                style: Mag.headline(26, color: scheme.onSurface).copyWith(height: 1.0)),
            const SizedBox(height: 12),
            Text(about.text!, style: Mag.quote(15, color: scheme.onSurface).copyWith(height: 1.3)),
            if (about.source != null) ...[
              const SizedBox(height: 14),
              Text('From ${about.source}'.toUpperCase(),
                  style: Mag.typewriter(10, color: scheme.onSurfaceVariant, bold: true)),
            ],
          ],
        ),
      );
    },
  );
}

/// A Bandcamp act or label: the page a follow of it opens as.
///
/// A label's page is its acts and its records, each record saying whose it is; an
/// act's is its records. Either can be followed from here, and either has its own
/// words behind the About button when it wrote any.
class BandcampBandPage extends StatefulWidget {
  const BandcampBandPage({super.key, required this.url, this.name});
  final String url;
  final String? name;

  @override
  State<BandcampBandPage> createState() => _BandcampBandPageState();
}

class _BandcampBandPageState extends State<BandcampBandPage> {
  late Future<BandcampBand> _future;
  bool? _following;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _future = context.read<AppState>().api.bandcampBand(widget.url);
  }

  void _reload() => setState(() {
        _future = context.read<AppState>().api.bandcampBand(widget.url);
      });

  Future<void> _toggleFollow(BandcampBand band) async {
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    final was = _following ?? band.following;
    setState(() {
      _working = true;
      _following = !was;
    });
    try {
      if (was) {
        await api.unfollow(band.url, provider: 'bandcamp');
      } else {
        await api.follow(remoteId: band.url, name: band.name, image: band.image, provider: 'bandcamp');
        messenger.say(snack(Text(band.isLabel
            ? 'Following ${band.name} — what it puts out shows up in Discover'
            : 'Following ${band.name} — new records show up in Discover')));
      }
    } catch (e) {
      setState(() => _following = was);
      messenger.say(problem(e));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PlayerScaffold(
      appBar: AppBar(title: Text(widget.name ?? 'On Bandcamp')),
      body: FutureBuilder<BandcampBand>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _reload);
          if (!snap.hasData) return const SongsComing(rows: 6);
          final band = snap.data!;
          final following = _following ?? band.following;
          return ListView(
            padding: EdgeInsets.fromLTRB(0, 8, 0, bottomForPlayer(context)),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: band.image != null
                          ? Artwork(url: band.image, size: 96, radius: 4, small: false)
                          : PrintedSleeve(seed: PrintedSleeve.seedOf(band.name), title: band.name, size: 96),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Kicker(band.isLabel ? 'Label · Bandcamp' : 'On Bandcamp'),
                          Text(band.name.toUpperCase(),
                              style: Mag.headline(30, color: scheme.onSurface).copyWith(height: 0.98)),
                          const SizedBox(height: 4),
                          Text(
                            [
                              if (band.isLabel) '${band.roster.length} acts',
                              '${band.records.length} records',
                            ].join(' · ').toUpperCase(),
                            style: Mag.typewriter(11, color: scheme.onSurfaceVariant, bold: true),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    PressButton(
                      label: _working ? '…' : following ? 'Following' : 'Follow',
                      loud: !following,
                      onTap: _working ? null : () => _toggleFollow(band),
                    ),
                    PressButton(
                      label: 'About',
                      onTap: () => showAbout(context, band.name, bandcamp: band.url, text: band.about),
                    ),
                  ],
                ),
              ),
              if (band.roster.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 22, 16, 4),
                  child: SectionFlag('Acts'),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final act in band.roster)
                        InkWell(
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => BandcampBandPage(url: act.url, name: act.name))),
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(10, 6, 10, 5),
                            decoration: BoxDecoration(border: Border.all(color: scheme.onSurface, width: 1.1)),
                            child: Text(act.name.toUpperCase(), style: Mag.flag(10.5, color: scheme.onSurface)),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 22, 16, 4),
                child: SectionFlag(band.isLabel ? 'Records on the label' : 'Records'),
              ),
              if (band.records.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Nothing on the page yet.', style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
                )
              else
                for (final r in band.records)
                  ListTile(
                    leading: r.cover != null
                        ? Artwork(url: r.cover, size: 48, radius: 0)
                        : PrintedSleeve(seed: PrintedSleeve.seedOf('${r.artist}·${r.title}'), title: r.title, size: 48),
                    title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        [if (r.artist != null && band.isLabel) r.artist!, if (r.recordType != null) r.recordType!]
                            .join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => BandcampRecordPage(url: r.url, title: r.title))),
                  ),
            ],
          );
        },
      ),
    );
  }
}
