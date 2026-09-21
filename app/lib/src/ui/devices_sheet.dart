import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'dialogs.dart';
import 'snack.dart';
import 'when.dart';
import 'widths.dart';

/// Where the music comes out.
///
/// One account, several things to listen on, and until now no way to say which — two
/// of them could be playing the same song at once, and moving from the desk to the
/// kitchen meant finding your place again by hand. This is the list of them, which one
/// has the music, and one tap to move it, from exactly where it has got to.
Future<void> showDevices(BuildContext context) async {
  final app = context.read<AppState>();
  unawaited(app.refreshDevices());
  await ask<void>(
    context,
    scrollable: true,
    builder: (_) => const _Devices(),
  );
}

class _Devices extends StatelessWidget {
  const _Devices();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final here = app.devices.where((d) => d.isThis).firstOrNull;
    // Everything else of yours, the ones that have said something lately first: a
    // phone that has been in a drawer since March is still yours and is not an answer
    // to "where shall this play".
    final others = [
      for (final d in app.devices)
        if (!d.isThis) d
    ]..sort((a, b) {
        if (a.live != b.live) return a.live ? -1 : 1;
        return (b.lastSeen ?? DateTime(1970))
            .compareTo(a.lastSeen ?? DateTime(1970));
      });

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
            child: Row(
              children: [
                Icon(Icons.speaker_group_outlined, size: 20, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Where it plays', style: text.titleMedium),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: 'Look again',
                  onPressed: app.refreshDevices,
                ),
              ],
            ),
          ),
          if (here != null) _DeviceRow(device: here),
          if (others.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
              child: Text('Your other devices', style: text.labelMedium),
            ),
          for (final d in others) _DeviceRow(device: d),
          if (others.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: Text(
                'Sign in on another phone or in another browser and it will '
                'appear here, ready to be handed the music.',
                style: text.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device});
  final DeviceInfo device;

  IconData get _icon => switch (device.kind ?? device.platform ?? '') {
        'browser' || 'web' => Icons.language,
        'desktop' || 'linux' || 'windows' => Icons.desktop_windows_outlined,
        'android' || 'phone' || 'ios' => Icons.smartphone,
        _ => Icons.devices_other,
      };

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // The one making the sound, which is the only thing anybody is looking for here.
    final sounding = device.playing;
    final chosen = sounding || (device.isThis && app.playingOn == null);

    return ListTile(
      leading: Icon(_icon,
          color: chosen ? scheme.primary : scheme.onSurfaceVariant),
      title: Row(
        children: [
          Flexible(
            child: Text(device.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: chosen ? TextStyle(color: scheme.primary) : null),
          ),
          if (device.isThis)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('this one', style: text.labelSmall),
            ),
        ],
      ),
      subtitle: Text(
        sounding && device.track != null
            ? '${device.track!.displayTitle} · ${device.track!.artistLine}'
            : device.live
                ? (device.queue == null ? 'Ready' : 'Ready · ${device.queue}')
                // Not "Not answering" alone: whether a phone went quiet a minute ago
                // or in March is the difference between waiting for it and giving up
                // on it.
                : 'Not answering · last heard from ${ago(device.lastSeen)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: sounding
          ? Icon(Icons.graphic_eq, color: scheme.primary)
          : device.track != null && !device.isThis
              ? Artwork(track: device.track, size: 32, radius: 4)
              : null,
      // A device nobody has heard from cannot be handed anything; it is listed so you
      // know it exists, and so you can give it a name for when it comes back.
      enabled: device.live || device.isThis,
      onLongPress: () => _rename(context),
      onTap: () async {
        final messenger = ScaffoldMessenger.of(context);
        final navigator = Navigator.of(context);
        try {
          await app.playOn(device);
          navigator.pop();
          messenger.say(snack(Text(device.isThis
              ? 'Playing here'
              : 'Playing on ${device.name}')));
        } catch (e) {
          messenger.say(problem(e));
        }
      },
    );
  }

  Future<void> _rename(BuildContext context) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final name = await promptForName(
        context, 'Name this device', device.name, 'Name',
        'The name the other screens will call it — "Kitchen", "The desk".');
    if (name == null || name.trim().isEmpty) return;
    try {
      await app.api.renameDevice(device.id, name.trim());
      await app.refreshDevices();
    } catch (e) {
      messenger.say(problem(e));
    }
  }
}

/// The button that opens it: a speaker with the name of wherever the music is.
///
/// It says where rather than only offering to change it — the question people have is
/// "why is nothing coming out of this laptop", and the answer is the name of the phone
/// in the next room.
class WhereItPlays extends StatelessWidget {
  const WhereItPlays({super.key, this.compact = false, this.size = 22});
  final double size;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final there = app.elsewhere;
    final somewhereElse = there != null;
    if (compact || Width.of(context) == Width.compact) {
      return IconButton(
        icon: Icon(
            somewhereElse ? Icons.speaker_group : Icons.speaker_group_outlined,
            size: size,
            color: somewhereElse ? scheme.primary : null),
        tooltip: somewhereElse ? 'Playing on ${there.name}' : 'Where it plays',
        onPressed: () => showDevices(context),
      );
    }
    return TextButton.icon(
      onPressed: () => showDevices(context),
      icon: Icon(
          somewhereElse ? Icons.speaker_group : Icons.speaker_group_outlined,
          size: size,
          color: somewhereElse ? scheme.primary : null),
      label: Text(somewhereElse ? there.name : 'This device',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: somewhereElse ? TextStyle(color: scheme.primary) : null),
    );
  }
}
