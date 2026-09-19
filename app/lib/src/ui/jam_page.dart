import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'face.dart';
import 'glass.dart';
import 'mini_player.dart';
import 'snack.dart';
import 'widths.dart';

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
        padding: EdgeInsets.fromLTRB(16, 8, 16, bottomForPlayer(context)),
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
    List<({int id, String name, bool online, String? avatarVersion})> people;
    try {
      people = await app.api.jamPeople();
    } catch (e) {
      messenger.say(snack(Text('$e')));
      return;
    }
    if (!context.mounted) return;
    final already = {for (final m in app.jam?.members ?? const <JamMember>[]) m.userId};

    await ask<void>(
      context,
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
                leading: Opacity(
                  opacity: person.online ? 1 : 0.45,
                  child: Face(
                      name: person.name,
                      userId: person.id,
                      version: person.avatarVersion,
                      size: 36),
                ),
                title: Text(person.name),
                subtitle: Text(already.contains(person.id)
                    ? 'already here'
                    : (person.online ? 'around now' : 'not around')),
                enabled: !already.contains(person.id),
                onTap: () async {
                  Navigator.of(sheet).pop();
                  try {
                    await app.inviteToJam(person.id);
                    messenger.say(
                        snack(Text('${person.name} is in')));
                  } catch (e) {
                    messenger.say(snack(Text('$e')));
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
        Text('Rooms with the lights on',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Everybody here has an account on this server, so a jam that is running is '
          'something to walk into.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        _OpenJams(onJoin: (code) => _run(() => app.joinJam(code))),
        const SizedBox(height: 18),
        Text('Or type a code', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
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
                    ScaffoldMessenger.of(context).say(
                        snack(Text('Code copied')));
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
      // Only a guest chooses: the host's device *is* the room's speaker.
      if (!jam.isHost) ...[
        const SizedBox(height: 14),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(app.jamListening
              ? Icons.headset
              : Icons.headset_off_outlined),
          title: const Text('Play it here too'),
          subtitle: Text(app.jamListening
              ? 'This device is playing along with the room'
              : 'Following the room without making a sound — turn this on if '
                  'you are somewhere else'),
          value: app.jamListening,
          onChanged: (on) => app.setJamListening(on),
        ),
      ],
      const SizedBox(height: 22),
      Text('Who is here', style: Theme.of(context).textTheme.titleSmall),
      for (final m in jam.members)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Opacity(
            // Away is drawn faintly rather than differently: it is the same person.
            opacity: m.online ? 1 : 0.45,
            child: Face(
                name: m.name, userId: m.userId, version: m.avatarVersion, size: 40),
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


/// The jams running right now, as a list you can walk into.
class _OpenJams extends StatefulWidget {
  const _OpenJams({required this.onJoin});
  final void Function(String code) onJoin;

  @override
  State<_OpenJams> createState() => _OpenJamsState();
}

class _OpenJamsState extends State<_OpenJams> {
  Future<List<OpenJam>>? _future;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    _load();
    // Somebody starting a jam in the next room should appear here without anyone
    // pulling the screen down.
    _refresh = Timer.periodic(const Duration(seconds: 12), (_) => _load());
  }

  void _load() {
    if (!mounted) return;
    setState(() => _future = context.read<AppState>().api.openJams());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<OpenJam>>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) {
          return Text('Could not ask who is listening: ${snap.error}',
              style: Theme.of(context).textTheme.bodySmall);
        }
        final rooms = snap.data;
        if (rooms == null) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        if (rooms.isEmpty) {
          return Text('Nobody is listening together at the moment.',
              style: Theme.of(context).textTheme.bodySmall);
        }
        return Column(
          children: [
            for (final room in rooms)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Face(
                      name: room.host,
                      version: room.hostAvatar,
                      // The picture belongs to the host; the id comes with the jam's
                      // own member list once you are in it, so outside a room the
                      // initial stands in.
                      size: 40),
                  title: Text("${room.host}'s jam"),
                  subtitle: Text(
                    [
                      room.nowPlaying,
                      '${room.listening} listening',
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: FilledButton.tonal(
                    onPressed: () => widget.onJoin(room.code),
                    child: const Text('Join'),
                  ),
                  onTap: () => widget.onJoin(room.code),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _load,
                icon: Icon(Icons.refresh, size: 18, color: scheme.outline),
                label: Text('Look again',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            ),
          ],
        );
      },
    );
  }
}
