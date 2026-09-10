import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'glass.dart';
import 'mini_player.dart';

/// Listening together: one queue, several people, different rooms.
///
/// The host's device is the one making sound. Everyone else sees what is on, puts
/// things on next, and can ask for a skip — which takes more than one voice.
class JamPage extends StatefulWidget {
  const JamPage({super.key});

  @override
  State<JamPage> createState() => _JamPageState();
}

class _JamPageState extends State<JamPage> {
  Object? _error;
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final jam = app.jam;

    return PlayerScaffold(
      appBar: AppBar(title: const Text('Jam')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('$_error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (jam == null) ..._invitations(context, app) else ..._running(context, app, jam),
        ],
      ),
    );
  }

  /// Everyone with an account here, and a tap to put them in the room.
  Future<void> _invite(BuildContext context, AppState app) async {
    final messenger = ScaffoldMessenger.of(context);
    List<({int id, String name, bool online})> people;
    try {
      people = await app.api.jamPeople();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    if (!context.mounted) return;
    final already = {for (final m in app.jam?.members ?? const <JamMember>[]) m.userId};

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Invite someone'),
            ),
            if (people.isEmpty)
              const ListTile(title: Text('Nobody else has an account here')),
            for (final person in people)
              ListTile(
                leading: Icon(person.online ? Icons.person : Icons.person_outline),
                title: Text(person.name),
                subtitle: Text(already.contains(person.id)
                    ? 'already here'
                    : (person.online ? 'around now' : 'not around')),
                enabled: !already.contains(person.id),
                onTap: () async {
                  Navigator.of(sheet).pop();
                  try {
                    await app.inviteToJam(person.id);
                    messenger.showSnackBar(
                        SnackBar(content: Text('${person.name} is in')));
                  } catch (e) {
                    messenger.showSnackBar(SnackBar(content: Text('$e')));
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _invitations(BuildContext context, AppState app) => [
        Text('Listen together',
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'Open your queue to other people. They can see what is on and put songs on '
          'next from their own device — your device keeps playing.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          icon: const Icon(Icons.podcasts),
          label: Text(app.activeQueue == null
              ? 'Open a queue first'
              : 'Start a jam from "${app.activeQueue!.name}"'),
          onPressed: _busy || app.activeQueue == null
              ? null
              : () => _run(app.startJam),
        ),
        const SizedBox(height: 26),
        const Divider(),
        const SizedBox(height: 14),
        Text('Join someone else', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        _JoinField(onJoin: (code) => _run(() => app.joinJam(code))),
      ];

  List<Widget> _running(BuildContext context, AppState app, Jam jam) {
    final scheme = Theme.of(context).colorScheme;
    return [
      GlassSurface(
        borderRadius: BorderRadius.circular(20),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.podcasts, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                      jam.isHost ? 'Your jam' : "${jam.host ?? 'Someone'}'s jam",
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                Text('${jam.listening} listening',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 4),
            Text(jam.rules, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(
              children: [
                if (jam.isHost)
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.person_add_alt, size: 18),
                    label: const Text('Invite'),
                    onPressed: _busy ? null : () => _invite(context, app),
                  ),
                const SizedBox(width: 8),
                // The code is for reaching somebody who is not on this server's list —
                // read out over a phone, typed in later. Everyone here already has an
                // account, so it is the fallback and not the way in.
                TextButton.icon(
                  icon: const Icon(Icons.tag, size: 18),
                  label: Text(jam.code,
                      style: const TextStyle(letterSpacing: 3)),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: jam.code));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Code copied')));
                  },
                ),
                const Spacer(),
                TextButton(
                  onPressed: _busy ? null : () => _run(app.leaveJam),
                  child: Text(jam.isHost ? 'End jam' : 'Leave'),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 22),
      Text('Who is here', style: Theme.of(context).textTheme.titleSmall),
      for (final m in jam.members)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(
            backgroundColor: m.online ? scheme.primaryContainer : scheme.surfaceContainerHighest,
            child: Text(m.name.isEmpty ? '?' : m.name[0].toUpperCase()),
          ),
          title: Text(m.name),
          subtitle: Text(m.host ? 'Host · playing' : (m.online ? 'Listening' : 'Away')),
          trailing: jam.isHost && !m.host
              ? IconButton(
                  icon: const Icon(Icons.person_remove_outlined, size: 20),
                  tooltip: 'Remove from jam',
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                            await app.api.removeFromJam(jam.id, m.userId);
                            await app.refreshJam();
                          }),
                )
              : null,
        ),
      const SizedBox(height: 18),
      const Divider(),
      Text(
        jam.isHost
            ? 'Everybody here is listening to this queue, in step with you. Anyone can '
                'add a song, and anyone can play, pause or skip — it moves the whole '
                'room, not just their own phone.'
            : 'You are listening to ${jam.host ?? 'the host'}\'s queue, in step with '
                'everybody else. Add a song, or play, pause and skip: it moves the '
                'whole room.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ];
  }
}

class _JoinField extends StatefulWidget {
  const _JoinField({required this.onJoin});
  final void Function(String code) onJoin;

  @override
  State<_JoinField> createState() => _JoinFieldState();
}

class _JoinFieldState extends State<_JoinField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            autocorrect: false,
            textCapitalization: TextCapitalization.characters,
            maxLength: 6,
            decoration: const InputDecoration(
              labelText: 'Jam code',
              hintText: 'ABC123',
              counterText: '',
            ),
            style: const TextStyle(letterSpacing: 6),
            onSubmitted: widget.onJoin,
          ),
        ),
        const SizedBox(width: 12),
        FilledButton(
          onPressed: () => widget.onJoin(_controller.text),
          child: const Text('Join'),
        ),
      ],
    );
  }
}

/// Opens the jam screen from wherever the user is.
Future<void> showJam(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute(builder: (_) => const JamPage()));
