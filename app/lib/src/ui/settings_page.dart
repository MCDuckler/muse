import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'dialogs.dart';
import 'spotify_page.dart';
import 'track_menu.dart';

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

  void _load() => setState(() => _storage = context.read<AppState>().api.storage());

  String _size(num bytes) {
    if (bytes >= 1e9) return '${(bytes / 1e9).toStringAsFixed(2)} GB';
    if (bytes >= 1e6) return '${(bytes / 1e6).toStringAsFixed(1)} MB';
    return '${(bytes / 1e3).toStringAsFixed(0)} kB';
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
          _label(context, 'Downloads'),
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
            leading: const Icon(Icons.music_note_outlined),
            title: const Text('Spotify'),
            subtitle: const Text('See and play your playlists here'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SpotifyPage())),
          ),
          const Divider(),
          _label(context, 'Account'),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(app.user ?? 'Signed in'),
            subtitle: Text(app.api.baseUrl),
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
