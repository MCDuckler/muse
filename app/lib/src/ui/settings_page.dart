import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'dialogs.dart';
import '../state/offline.dart';
import '../state/art_cache.dart';
import '../state/updates.dart';
import 'kept_page.dart';
import 'face.dart';
import 'downloads_page.dart';
import 'player_look_page.dart';
import 'services_page.dart';
import 'accounts_page.dart';
import 'playback_log_page.dart';
import 'track_menu.dart';
import 'theme.dart';
import 'snack.dart';

const appVersion = '0.1.0';

/// The moment this build was made, as `YYYYMMDDHHMM`, put in by the publisher.
///
/// Empty in anything not built by deploy/publish.sh — a debug build somebody is
/// working in — and an app that does not know when it was made never claims to be out
/// of date.
const appBuild = String.fromEnvironment('MUSE_BUILD');

/// Where the answers to "is this thing working" live.
///
/// Until now there was nowhere to see which server you were talking to, how much
/// music you had, or whether the machine that downloads it was even awake — and
/// signing out meant finding an overflow menu.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Future<Map<String, dynamic>>? _storage;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // A block body, not an arrow: `() => _x = future` returns that future, and
  // setState refuses a callback that returns one.
  void _load() {
    final pending = context.read<AppState>().api.storage();
    setState(() { _storage = pending; });
  }

  String _size(num bytes) {
    if (bytes >= 1e9) return '${(bytes / 1e9).toStringAsFixed(2)} GB';
    if (bytes >= 1e6) return '${(bytes / 1e6).toStringAsFixed(1)} MB';
    return '${(bytes / 1e3).toStringAsFixed(0)} kB';
  }

  bool _pickingFace = false;

  /// A picture for the account. It shows up beside your name here, on who is in a jam,
  /// and against the songs you put in a shared queue.
  Future<void> _pickFace(AppState app) async {
    final messenger = ScaffoldMessenger.of(context);
    final file = await FilePicker.pickFile(type: FileType.image);
    if (file == null || !mounted) return;
    setState(() => _pickingFace = true);
    try {
      await app.setAvatar(await file.readAsBytes());
    } catch (e) {
      messenger.showSnackBar(snack(Text('$e')));
    } finally {
      if (mounted) setState(() => _pickingFace = false);
    }
  }

  Future<void> _upload() async {
    // Read the bytes rather than a path: the web build never has one.
    final file = await FilePicker.pickFile(type: FileType.audio);
    if (file == null || !mounted) return;

    if (!mounted) return;
    // Capture both before any await: the picker can sit open for a long time, and a
    // context used after that is a context that may no longer be in the tree.
    final messenger = ScaffoldMessenger.of(context);
    final app = context.read<AppState>();
    setState(() => _uploading = true);
    try {
      final bytes = await file.readAsBytes();
      final track = await app.api.upload(bytes, file.name);
      _load();
      if (!mounted) return;
      messenger.showSnackBar(snack(Text(track.state == 'ready'
            ? 'Added ${track.displayTitle}'
            : 'Uploaded ${file.name}'),
        action: SnackBarAction(
          label: 'Edit details',
          // Tags written by whoever made the file are a suggestion, so the fastest
          // path from "uploaded" to "correct" is offered right here.
          onPressed: () {
            if (mounted) editTrackDialog(context, track);
          },
        ),
      ));
    } catch (e) {
      messenger.showSnackBar(snack(Text('$e')));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          _label(context, 'Your music'),
          ListTile(
            leading: _uploading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.upload_file),
            title: const Text('Upload a file'),
            subtitle: const Text('Add a track the downloader cannot fetch'),
            onTap: _uploading ? null : _upload,
          ),
          FutureBuilder<Map<String, dynamic>>(
            future: _storage,
            builder: (context, snap) {
              if (snap.hasError) {
                return ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: const Text('Could not read the library size'),
                  trailing: TextButton(onPressed: _load, child: const Text('Retry')),
                );
              }
              if (!snap.hasData) {
                return const ListTile(
                  leading: Icon(Icons.storage_outlined),
                  title: Text('Library'),
                  subtitle: Text('Counting…'),
                );
              }
              final d = snap.data!;
              final tracks = (d['tracks'] as Map?) ?? {};
              final ready = tracks['ready'] ?? 0;
              final failed = tracks['failed'] ?? 0;
              return ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: const Text('Library'),
                subtitle: Text([
                  '$ready ready',
                  if (failed != 0) '$failed failed',
                  '${d['covers'] ?? 0} covers',
                  _size((d['bytes'] ?? 0) as num),
                ].join(' · ')),
              );
            },
          ),
          const Divider(),
          _label(context, 'Player'),
          ListTile(
            leading: const Icon(Icons.play_circle_outline),
            title: const Text('Now playing'),
            subtitle: Text('${app.playerLayout.label} · '
                '${app.coverStyle.label.toLowerCase()}'
                '${app.halftone ? ' · printed background' : ''}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const PlayerLookPage())),
          ),
          const Divider(),
          _label(context, 'Colours'),
          // Swatches rather than a list of names: the choice is a look, and reading
          // "Midnight" tells you less than seeing it.
          SizedBox(
            height: 96,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final palette in Palette.all)
                  _Swatch(
                    palette: palette,
                    selected: app.palette.id == palette.id,
                    onTap: () => app.setPalette(palette),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
            child: Text(app.palette.blurb,
                style: Theme.of(context).textTheme.bodySmall),
          ),
          const Divider(),
          _label(context, 'Downloads'),
          if (OfflineStore.supported)
            ListTile(
              leading: const Icon(Icons.phone_iphone),
              title: const Text('Kept on this device'),
              subtitle: Text(app.offline.count == 0
                  ? 'Nothing yet — keep a song, a record or a playlist for no signal'
                  : '${app.offline.count} songs · '
                      '${KeptPage.size(app.offline.bytes)}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const KeptPage())),
            ),
          if (ArtCache.supported) const _ArtCacheRow(),
          ListTile(
            leading: const Icon(Icons.downloading),
            title: const Text('Download queue'),
            subtitle: Text(app.downloadsPending == 0
                ? 'Nothing waiting'
                : '${app.downloadsPending} waiting'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const DownloadsPage())),
          ),
          ListTile(
            leading: Icon(app.ingestOnline ? Icons.cloud_done : Icons.cloud_off,
                color: app.ingestOnline
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.error),
            title: Text(app.ingestOnline ? 'Downloader online' : 'Downloader offline'),
            subtitle: Text(app.ingestOnline
                ? 'New tracks download as soon as you add them'
                : 'Queued tracks will wait until it is back'),
            trailing: app.downloadsPending > 0
                ? Chip(label: Text('${app.downloadsPending} waiting'))
                : null,
          ),
          const Divider(),
          _label(context, 'Connected services'),
          ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: const Text('Connected services'),
            subtitle: const Text(
                'Spotify, YouTube Music, Deezer, SoundCloud, Bandcamp'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const ServicesPage())),
          ),
          const Divider(),
          _label(context, 'Account'),
          ListTile(
            leading: Face(
                name: app.user, userId: app.userId, version: app.avatarVersion),
            title: Text(app.user ?? 'Signed in'),
            subtitle: Text(app.api.baseUrl),
            trailing: TextButton(
              onPressed: _pickingFace ? null : () => _pickFace(app),
              child: Text(app.avatarVersion == null ? 'Add photo' : 'Change'),
            ),
            onLongPress: app.avatarVersion == null
                ? null
                : () async {
                    if (await confirm(context, 'Remove your photo?',
                        'Your name goes back to standing on its own.')) {
                      await app.clearAvatar();
                    }
                  },
          ),
          ListTile(
            leading: const Icon(Icons.group_outlined),
            title: const Text('Accounts'),
            subtitle: Text(app.score == 0
                ? 'Invite someone, or add an account'
                : '${app.score} ${app.score == 1 ? 'record' : 'records'} heard '
                    'all the way through'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const AccountsPage())),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: () async {
              final ok = await confirm(context, 'Sign out?',
                  'You will need your password to sign back in.');
              if (!ok) return;
              await app.logout();
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('Playback log'),
            subtitle: const Text('What the audio engine did, and when'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const PlaybackLogPage())),
          ),
          if (Updates.supported) const _UpdateRow(),
          const _ApkRow(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Muse'),
            subtitle: Text(appBuild.isEmpty
                ? 'Version $appVersion'
                : 'Version $appVersion · build $appBuild'),
          ),
        ],
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Text(text.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}


/// One palette, as the two colours it is made of.
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  final Palette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ground = dark ? palette.groundDark : palette.groundLight;
    final accent = dark ? palette.accentDark : palette.accentLight;

    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: ground,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected
                      ? accent
                      : Theme.of(context).colorScheme.outlineVariant,
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: Center(
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(palette.name, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}

/// How much artwork is being kept, and a way to be rid of it.
///
/// Covers download once and stay, which is the whole point — but a store with no size
/// on it and no way to empty it is a store people are right not to trust.
class _ArtCacheRow extends StatefulWidget {
  const _ArtCacheRow();

  @override
  State<_ArtCacheRow> createState() => _ArtCacheRowState();
}

class _ArtCacheRowState extends State<_ArtCacheRow> {
  int? _bytes;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final n = await ArtCache.size();
    if (mounted) setState(() => _bytes = n);
  }

  @override
  Widget build(BuildContext context) => ListTile(
        leading: const Icon(Icons.image_outlined),
        title: const Text('Album art on this device'),
        subtitle: Text(_bytes == null
            ? 'Measuring…'
            : _bytes == 0
                ? 'Nothing yet — covers are kept as you play them'
                : '${KeptPage.size(_bytes!)} · covers load instantly and work '
                    'with no signal'),
        trailing: (_bytes ?? 0) == 0
            ? null
            : TextButton(
                onPressed: () async {
                  await ArtCache.forgetAll();
                  await _measure();
                },
                child: const Text('Clear'),
              ),
      );
}

/// Whether there is a newer app, and getting it.
///
/// Says what it is doing at every step and never more than it is doing. The last step
/// is the system's own installer, which is as far as an app that is not the owner of
/// the device is allowed to go — so this fetches everything, checks it arrived whole,
/// and then asks once.
/// The Android app itself, from wherever you are reading this.
///
/// The update row above only appears on a phone, and only when the server has a newer
/// build than the one running — so on the web app, where somebody is most likely to be
/// looking for it, there was no way to reach the APK at all short of typing the URL.
/// This is always here: how big it is, when it was built, and the one link.
class _ApkRow extends StatefulWidget {
  const _ApkRow();

  @override
  State<_ApkRow> createState() => _ApkRowState();
}

class _ApkRowState extends State<_ApkRow> {
  Release? _release;
  bool _looked = false;
  Updates? _updates;

  String get _base => context.read<AppState>().api.baseUrl;

  @override
  void initState() {
    super.initState();
    unawaited(_look());
  }

  Future<void> _look() async {
    final found = await Updates.published(_base);
    if (mounted) setState(() { _release = found; _looked = true; });
  }

  @override
  void dispose() {
    _updates?.dispose();
    super.dispose();
  }

  /// On a phone the file is no use as a download — it has to reach the installer — so
  /// it takes the same path an update does: fetched, checked, offered. Anywhere else
  /// it is a file to save and carry to a phone, which the browser does far better than
  /// this app could.
  Future<void> _get() async {
    final messenger = ScaffoldMessenger.of(context);
    if (Updates.supported) {
      final u = _updates ??= Updates(baseUrl: _base, running: appBuild)
        ..addListener(() { if (mounted) setState(() {}); });
      if (u.release == null) await u.look();
      await u.fetchAndOffer();
      return;
    }
    final url = Uri.parse(Updates.apkUrl(_base));
    final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!opened) {
      messenger.showSnackBar(snack(const Text('Could not open the download')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = _updates;
    final downloading = u?.state == Updating.downloading;
    final release = _release;
    return ListTile(
      leading: const Icon(Icons.android),
      title: const Text('Android app'),
      subtitle: downloading
          ? Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(value: u!.progress),
            )
          : Text(!_looked
              ? 'Looking…'
              : release == null
                  ? 'Nothing published on this server yet'
                  : [
                      release.size,
                      if (release.built != null)
                        'built ${release.built!.split('T').first}',
                    ].join(' · ')),
      trailing: release == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.link),
                  tooltip: 'Copy the link',
                  onPressed: () {
                    Clipboard.setData(
                        ClipboardData(text: Updates.apkUrl(_base)));
                    ScaffoldMessenger.of(context)
                        .showSnackBar(snack(const Text('Link copied')));
                  },
                ),
                FilledButton.tonal(
                  onPressed: downloading ? null : _get,
                  child: Text(Updates.supported ? 'Install' : 'Download'),
                ),
              ],
            ),
    );
  }
}

class _UpdateRow extends StatefulWidget {
  const _UpdateRow();

  @override
  State<_UpdateRow> createState() => _UpdateRowState();
}

class _UpdateRowState extends State<_UpdateRow> {
  Updates? _updates;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _updates = Updates(baseUrl: app.api.baseUrl, running: appBuild)
      ..addListener(_changed);
    unawaited(_updates!.look());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _updates?.removeListener(_changed);
    _updates?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final u = _updates;
    if (u == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    if (u.state == Updating.downloading) {
      return ListTile(
        leading: const Icon(Icons.download),
        title: const Text('Getting the new version'),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: LinearProgressIndicator(value: u.progress),
        ),
        trailing: Text('${(u.progress * 100).round()}%',
            style: Theme.of(context).textTheme.labelMedium),
      );
    }

    if (u.state == Updating.waiting) {
      return ListTile(
        leading: Icon(Icons.system_update, color: scheme.primary),
        title: const Text('Ready to install'),
        subtitle: const Text('Android asks before it installs anything — say yes'),
        trailing: FilledButton(
          onPressed: u.offer,
          child: const Text('Install'),
        ),
      );
    }

    if (u.state == Updating.failed) {
      return ListTile(
        leading: Icon(Icons.error_outline, color: scheme.error),
        title: const Text('That did not work'),
        subtitle: Text(u.trouble ?? 'Unknown'),
        trailing: TextButton(
            onPressed: u.fetchAndOffer, child: const Text('Again')),
      );
    }

    if (!u.available) {
      return ListTile(
        leading: const Icon(Icons.check_circle_outline),
        title: const Text('Up to date'),
        subtitle: Text(u.state == Updating.checking
            ? 'Looking…'
            : appBuild.isEmpty
                ? 'This build was not made by the publisher'
                : 'This is the newest version on the server'),
        trailing: IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Check again',
          onPressed: u.look,
        ),
      );
    }

    final release = u.release!;
    return ListTile(
      leading: Icon(Icons.system_update, color: scheme.primary),
      title: Text('Version ${release.version} is ready'),
      subtitle: Text(Release.knows(appBuild)
          ? '${release.size}'
              '${release.built == null ? '' : ' · built ${release.built!.split('T').first}'}'
          // Honest about why: this copy predates the app knowing when it was built, so
          // "newer" is an assumption rather than a comparison.
          : '${release.size} · this copy does not say when it was built'),
      trailing: FilledButton(
        onPressed: u.fetchAndOffer,
        child: const Text('Update'),
      ),
    );
  }
}
