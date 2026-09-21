import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'snack.dart';
import 'when.dart';

/// A listening diary kept somewhere else: what is played here, written down there.
///
/// ListenBrainz asks for nothing but a token pasted in from its settings page — no app
/// to register and no browser to be sent to — so it is one card, a dialog with one
/// field, and afterwards a line saying whether it is being written in. The token is
/// checked by the server before it is kept, and never comes back.
class ScrobblingCard extends StatefulWidget {
  const ScrobblingCard({super.key});

  @override
  State<ScrobblingCard> createState() => _ScrobblingCardState();
}

class _ScrobblingCardState extends State<ScrobblingCard> {
  Scrobbling? _standing;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  Future<void> _ask() async {
    try {
      final s = await context.read<AppState>().api.scrobbling();
      if (mounted) setState(() => _standing = s);
    } catch (_) {
      // A server from before this existed: the card is left off.
    }
  }

  Future<void> _connect() async {
    final token = await showDialog<String>(
        context: context, builder: (_) => const _TokenDialog());
    if (token == null || token.isEmpty || !mounted) return;
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _working = true);
    try {
      final s = await api.connectListenBrainz(token);
      if (mounted) setState(() => _standing = s);
      messenger.say(snack(Text('Writing to ${s.name ?? 'ListenBrainz'} from now on')));
    } catch (e) {
      messenger.say(problem(e));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _disconnect() async {
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _working = true);
    try {
      final s = await api.disconnectListenBrainz();
      if (mounted) setState(() => _standing = s);
    } catch (e) {
      messenger.say(problem(e));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _standing;
    if (s == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final said = !s.connected
        ? 'Keeps a diary of what you play, on listenbrainz.org. Paste a token; '
            'nothing else to set up.'
        : [
            'Writing to ${s.name ?? 'your account'}',
            // Said only when there is something to say: not "0 sent".
            if (s.sent > 0) '${s.sent} sent',
            if (s.owed > 0) '${s.owed} waiting to go',
            if (s.lastSent != null) 'last ${ago(s.lastSent)}',
          ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: Icon(s.connected ? Icons.edit_note : Icons.menu_book_outlined),
            title: const Text('ListenBrainz'),
            subtitle: Text(said),
            trailing: _working
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : TextButton(
                    onPressed: s.connected ? _disconnect : _connect,
                    child: Text(s.connected ? 'Stop' : 'Connect'),
                  ),
          ),
          if (s.connected && s.error != null && s.owed > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'The last try did not get through (${s.error}). Nothing is lost: '
                'it goes again with the next song.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

class _TokenDialog extends StatefulWidget {
  const _TokenDialog();

  @override
  State<_TokenDialog> createState() => _TokenDialogState();
}

class _TokenDialogState extends State<_TokenDialog> {
  final _token = TextEditingController();

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Connect ListenBrainz'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Your user token is on listenbrainz.org, under Settings. '
                'It is checked, kept on this server, and used only to write down '
                'what you play.'),
            const SizedBox(height: 12),
            TextField(
              controller: _token,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'User token'),
              onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(_token.text.trim()),
              child: const Text('Connect')),
        ],
      );
}
