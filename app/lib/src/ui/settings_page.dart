import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'dialogs.dart';
import '../state/offline.dart';
import 'kept_page.dart';
import 'face.dart';
import 'downloads_page.dart';
import 'player_look_page.dart';
import 'services_page.dart';
import 'accounts_page.dart';
import 'playback_log_page.dart';
import 'track_menu.dart';
import 'theme.dart';

const appVersion = '0.1.0';

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
      messenger.showSnackBar(SnackBar(content: Text('$e')));
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
      messenger.showSnackBar(SnackBar(
        content: Text(track.state == 'ready'
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
      messenger.showSnackBar(SnackBar(content: Text('$e')));
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
            subtitle: const Text('Invite someone, or add an account'),
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
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Muse'),
            subtitle: const Text('Version $appVersion'),
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
