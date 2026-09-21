
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'artwork.dart';
import 'dialogs.dart';
import 'snack.dart';
import 'record_refresh.dart';

/// The picture on everybody's home screen.
///
/// Served rather than built in, so changing it does not mean a new build and a new
/// install for everyone — the web app's manifest, its favicon and the icon iOS puts on
/// a home screen all ask the server for it. The launcher icon of an installed Android
/// app is the one thing that cannot follow: that one is inside the APK, and it changes
/// when a new APK does.
class AppIconRow extends StatefulWidget {
  const AppIconRow({super.key});

  @override
  State<AppIconRow> createState() => _AppIconRowState();
}

class _AppIconRowState extends State<AppIconRow> {
  ({String version, bool custom, bool mayChange})? _icon;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final got = await context.read<AppState>().api.appIcon();
      if (mounted) setState(() => _icon = got);
    } catch (_) {
      // An older server has no icon to ask about. The row simply says nothing.
    }
  }

  Future<void> _choose() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final file = await FilePicker.pickFile(type: FileType.image);
    if (file == null) return;
    setState(() => _busy = true);
    try {
      await app.api.setAppIcon(await file.readAsBytes());
      await _load();
      messenger.say(snack(const Text('That is the icon now')));
    } catch (e) {
      messenger.say(snack(Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revert() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await app.api.clearAppIcon();
      await _load();
      messenger.say(snack(const Text('Back to the one it came with')));
    } catch (e) {
      messenger.say(snack(Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final icon = _icon;
    if (icon == null) return const SizedBox.shrink();
    final api = context.read<AppState>().api;
    return ListTile(
      leading: Artwork(
        url: api.appIconUrl(size: 192, version: icon.version),
        size: 44,
        radius: 10,
      ),
      title: const Text('App icon'),
      subtitle: Text(icon.mayChange
          ? 'On the web and on a home screen. An installed Android app keeps the '
              'icon it was built with until the next one.'
          : 'Only an admin can change this'),
      trailing: !icon.mayChange
          ? null
          : _busy
              ? const SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon.custom)
                      IconButton(
                        icon: const Icon(Icons.undo),
                        tooltip: 'Use the one it came with',
                        onPressed: _revert,
                      ),
                    FilledButton.tonal(
                      onPressed: _choose,
                      child: const Text('Change'),
                    ),
                  ],
                ),
    );
  }
}

/// Who can sign in to this server.
///
/// There is still no public signup: an existing user either creates the account
/// outright, or hands out a one-time invite so the other person picks their own
/// password — which is better, because you should not know it.
class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key});

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  Future<({List<Map<String, dynamic>> items, int you})>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final pending = context.read<AppState>().api.accounts();
    setState(() { _future = pending; });
  }

  Future<void> _invite() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final invite = await app.api.createInvite();
      final code = invite['code'] as String;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Invite code'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Give this to the person joining. They enter it on the '
                  'sign-in screen and choose their own password.'),
              const SizedBox(height: 16),
              SelectableText(code,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontFamily: 'monospace')),
              const SizedBox(height: 12),
              Text('Works once, for ${invite['valid_hours']} hours.',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code));
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Copy'),
            ),
            FilledButton(
                onPressed: () => Navigator.pop(context), child: const Text('Done')),
          ],
        ),
      );
    } catch (e) {
      messenger.say(snack(Text('$e')));
    }
  }

  Future<void> _createDirectly() async {
    final name = TextEditingController();
    final password = TextEditingController();
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add an account'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              decoration: const InputDecoration(
                labelText: 'Password',
                helperText: 'At least 8 characters',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await app.api.createAccount(name.text.trim(), password.text);
      _load();
    } catch (e) {
      messenger.say(snack(Text('$e')));
    }
  }

  /// Somebody locked out should be recoverable from here, not from a database client.
  Future<void> _resetFor(Map<String, dynamic> account) async {
    final password = TextEditingController();
    var signOut = true;
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('New password for ${account['name']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: password,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: 'Password', helperText: 'At least 8 characters'),
              ),
              CheckboxListTile(
                value: signOut,
                onChanged: (v) => setLocal(() => signOut = v ?? true),
                title: const Text('Sign out their devices'),
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Set')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await app.api.resetPassword(account['id'] as int, password.text,
          signOutDevices: signOut);
      messenger.say(
          snack(Text('Password set for ${account['name']}')));
      _load();
    } catch (e) {
      messenger.say(snack(Text('$e')));
    }
  }

  Future<void> _changeMyPassword() async {
    final password = TextEditingController();
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change your password'),
        content: TextField(
          controller: password,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(
              labelText: 'New password', helperText: 'At least 8 characters'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await app.api.changePassword(password.text);
      messenger.say(snack(Text('Password changed')));
    } catch (e) {
      messenger.say(snack(Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Accounts')),
      body: FutureBuilder<({List<Map<String, dynamic>> items, int you})>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _load);
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final data = snap.data!;

          return RecordRefresh(
            onRefresh: () async => _load(),
            child: ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.key),
                  title: const Text('Invite someone'),
                  subtitle: const Text('They pick their own password'),
                  onTap: _invite,
                ),
                ListTile(
                  leading: const Icon(Icons.person_add_alt),
                  title: const Text('Add an account directly'),
                  subtitle: const Text('You choose the password for them'),
                  onTap: _createDirectly,
                ),
                ListTile(
                  leading: const Icon(Icons.password),
                  title: const Text('Change your password'),
                  onTap: _changeMyPassword,
                ),
                const Divider(),
                const AppIconRow(),
                const Divider(),
                // Most records heard first. A score nobody can see beside anybody
                // else's is a statistic; in an order it is a scoreboard.
                for (final a in ([...data.items]..sort((x, y) =>
                    ((y['score'] ?? 0) as int).compareTo((x['score'] ?? 0) as int))))
                  ListTile(
                    leading: CircleAvatar(
                      child: Text(((a['name'] ?? '?') as String)
                          .characters
                          .first
                          .toUpperCase()),
                    ),
                    title: Row(
                      children: [
                        Text('${a['name']}'),
                        if (a['id'] == data.you) ...[
                          const SizedBox(width: 8),
                          Text('you',
                              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: Theme.of(context).colorScheme.primary)),
                        ],
                        const Spacer(),
                        _Score(records: (a['score'] ?? 0) as int),
                      ],
                    ),
                    subtitle: Text([
                      '${a['devices'] ?? 0} devices',
                      if (a['last_seen'] != null)
                        'last seen ${(a['last_seen'] as String).split('T').first}',
                    ].join(' · ')),
                    trailing: a['id'] == data.you
                        ? null
                        : PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert),
                            onSelected: (v) async {
                              if (v == 'reset') {
                                await _resetFor(a);
                              } else {
                                final ok = await confirm(
                                    context,
                                    'Remove ${a['name']}?',
                                    'Their queues and playlists go with them. Tracks '
                                    'stay in the library.',
                                    action: 'Remove');
                                if (!ok || !context.mounted) return;
                                final messenger = ScaffoldMessenger.of(context);
                                try {
                                  await app.api.deleteAccount(a['id'] as int);
                                } catch (e) {
                                  messenger.say(problem(e));
                                }
                                _load();
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                  value: 'reset', child: Text('Set a new password…')),
                              PopupMenuItem(
                                  value: 'remove', child: Text('Remove account')),
                            ],
                          ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// How many records somebody has heard all the way through.
///
/// A count of finished listens, which is a thing that either happened or did not —
/// skipping through a hundred songs earns nothing, and sitting through one earns the
/// same as sitting through any other. That is the whole of the game.
class _Score extends StatelessWidget {
  const _Score({required this.records});
  final int records;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: records == 0 ? 0.06 : 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.album_outlined,
              size: 13,
              color: scheme.primary.withValues(alpha: records == 0 ? 0.4 : 1)),
          const SizedBox(width: 5),
          Text(
            '$records',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.primary.withValues(alpha: records == 0 ? 0.5 : 1),
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
          ),
        ],
      ),
    );
  }
}
