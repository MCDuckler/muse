import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'dialogs.dart';

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

  void _load() => setState(() => _future = context.read<AppState>().api.accounts());

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
      messenger.showSnackBar(SnackBar(content: Text('$e')));
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
      messenger.showSnackBar(SnackBar(content: Text('$e')));
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
      messenger.showSnackBar(
          SnackBar(content: Text('Password set for ${account['name']}')));
      _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
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
      messenger.showSnackBar(const SnackBar(content: Text('Password changed')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
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

          return RefreshIndicator(
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
                for (final a in data.items)
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
                                    'stay in the library.');
                                if (!ok) return;
                                await app.api.deleteAccount(a['id'] as int);
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
