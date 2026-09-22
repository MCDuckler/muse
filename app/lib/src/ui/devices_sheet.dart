import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'dialogs.dart';
import 'feel.dart';
import 'mag.dart';
import 'mag_parts.dart';
import 'snack.dart';
import 'song_row.dart';
import 'swipe.dart';
import 'when.dart';
import 'widths.dart';

/// Where the music comes out.
///
/// One account, several things to listen on. The music is on exactly one of them at a
/// time; every other screen of the account follows it — the same song, the same place
/// in it, the same play button — and any of them can take it over from where it has
/// got to, or tell the one that has it what to do. This is the list of them.
///
/// It used to be a plain list of every device that had ever signed in, most of them
/// called "flutter", with the one that mattered somewhere in the middle. Now: the one
/// with the music first and large, then the ones that could take it, and the ones
/// nobody has heard from in a while folded away with a way to be rid of them.
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

    final devices = app.devices;
    final here = devices.where((d) => d.isThis).firstOrNull;
    // The one making the sound: what it says, or, when nothing is playing anywhere,
    // this one — which is where a tap on play would put it.
    final sounding = app.elsewhere ??
        devices.where((d) => d.playing && d.live).firstOrNull ??
        here;
    final live = [
      for (final d in devices)
        if (d.id != sounding?.id && (d.live || d.isThis)) d
    ]..sort((a, b) {
        // This one first, then whoever spoke most recently.
        if (a.isThis != b.isThis) return a.isThis ? -1 : 1;
        return (b.lastSeen ?? DateTime(1970)).compareTo(a.lastSeen ?? DateTime(1970));
      });
    final quiet = [
      for (final d in devices)
        if (d.id != sounding?.id && !d.live && !d.isThis) d
    ]..sort((a, b) =>
        (b.lastSeen ?? DateTime(1970)).compareTo(a.lastSeen ?? DateTime(1970)));

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Row(
              children: [
                Expanded(child: Text('Where it plays', style: text.titleMedium)),
                if (devices.isEmpty)
                  const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.6)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              'Tap a device to move the music there, from where it has got to. '
              'Every screen of yours follows whichever one has it.',
              style: Mag.typewriter(11.5, color: scheme.onSurfaceVariant),
            ),
          ),
          if (sounding != null) _Sounding(device: sounding, app: app),
          if (live.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: SectionFlag('Play it on'),
            ),
            for (final d in live) _DeviceRow(device: d),
          ],
          if (live.isEmpty && devices.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
              child: Text(
                'Sign in on another phone or in another browser and it will '
                'appear here, ready to be handed the music.',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          if (quiet.isNotEmpty) _Quiet(devices: quiet),
        ],
      ),
    );
  }
}

/// The device with the music: the picture of what it is playing, its name, and the
/// sound itself moving. Or this device, ready, when nothing is playing anywhere.
class _Sounding extends StatelessWidget {
  const _Sounding({required this.device, required this.app});
  final DeviceInfo device;
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final track = device.track ?? (device.isThis ? app.player?.current : null);
    final playing = device.playing && device.live;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Material(
        color: scheme.primary.withValues(alpha: 0.10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: scheme.primary.withValues(alpha: 0.45), width: 1.2),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onLongPress: () => _rename(context, device),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Row(
              children: [
                if (track != null)
                  Artwork(track: track, size: 52, radius: 5)
                else
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Icon(iconFor(device), color: scheme.onSurfaceVariant),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        playing
                            ? 'Playing on ${labelFor(device)}'
                            : device.isThis
                                ? 'Ready here'
                                : 'Paused on ${labelFor(device)}',
                        style: Mag.flag(10, color: scheme.primary),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        track?.displayTitle ?? 'Nothing on',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall,
                      ),
                      if (track != null)
                        Text(track.artistLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(iconFor(device), size: 18, color: scheme.onSurfaceVariant),
                if (playing) ...[
                  const SizedBox(width: 10),
                  PlayingBars(playing: true, colour: scheme.primary, size: 18),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One of your devices that could take the music.
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device});
  final DeviceInfo device;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return RowChrome(
      onTap: () async {
        feel(Feel.commit);
        final messenger = ScaffoldMessenger.of(context);
        final navigator = Navigator.of(context);
        try {
          await app.playOn(device);
          navigator.pop();
          messenger.say(snack(Text(
              device.isThis ? 'Playing here' : 'Playing on ${labelFor(device)}')));
        } catch (e) {
          messenger.say(problem(e));
        }
      },
      onLongPress: () => _rename(context, device),
      onSecondaryTap: () => _rename(context, device),
      builder: (context, hovering) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Row(
          children: [
            Icon(iconFor(device), size: 22, color: scheme.onSurfaceVariant),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(labelFor(device),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyMedium),
                      ),
                      if (device.isThis)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text('THIS ONE', style: Mag.flag(8, color: scheme.outline)),
                        ),
                    ],
                  ),
                  Text(
                    device.track != null && !device.isThis
                        ? 'Ready · last on ${device.track!.displayTitle}'
                        : 'Ready',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Icon(hovering ? Icons.play_circle : Icons.play_circle_outline,
                size: 22, color: hovering ? scheme.primary : scheme.outline),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

/// The devices nobody has heard from lately, folded away: still yours, not offering
/// to play anything. Pushed aside, or from the menu, one is forgotten — which also
/// signs it out, so a browser on a machine you no longer have is no longer a way in.
class _Quiet extends StatelessWidget {
  const _Quiet({required this.devices});
  final List<DeviceInfo> devices;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.fromLTRB(20, 0, 16, 0),
        title: Text('Not seen lately · ${devices.length}',
            style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
        children: [
          for (final d in devices)
            SwipeAction(
              onSwipeAway: () => _forget(context, d),
              awayLabel: 'Forget',
              child: RowChrome(
                onLongPress: () => _quietMenu(context, d),
                onSecondaryTap: () => _quietMenu(context, d),
                builder: (context, _) => Padding(
                  padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
                  child: Row(
                    children: [
                      Icon(iconFor(d), size: 20, color: scheme.outline),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(labelFor(d),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodyMedium?.copyWith(color: scheme.outline)),
                            Text('Last heard from ${ago(d.lastSeen)}',
                                style: text.bodySmall?.copyWith(color: scheme.outline)),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.more_vert, size: 18),
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Rename or forget',
                        onPressed: () => _quietMenu(context, d),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Future<void> _quietMenu(BuildContext context, DeviceInfo device) async {
  await ask<void>(
    context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(labelFor(device), style: Theme.of(sheet).textTheme.titleMedium),
            subtitle: Text('Last heard from ${ago(device.lastSeen)}'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Rename…'),
            onTap: () {
              Navigator.of(sheet).pop();
              _rename(context, device);
            },
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Forget this device'),
            subtitle: const Text('It is signed out and gone from this list'),
            onTap: () {
              Navigator.of(sheet).pop();
              _forget(context, device);
            },
          ),
        ],
      ),
    ),
  );
}

Future<void> _forget(BuildContext context, DeviceInfo device) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    await app.forgetDevice(device.id);
    messenger.say(snack(Text('Forgot ${labelFor(device)}')));
  } catch (e) {
    messenger.say(problem(e));
  }
}

Future<void> _rename(BuildContext context, DeviceInfo device) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final name = await promptForName(
      context, 'Name this device', labelFor(device), 'Name',
      'The name the other screens will call it — "Kitchen", "The desk".');
  if (name == null || name.trim().isEmpty) return;
  try {
    await app.api.renameDevice(device.id, name.trim());
    await app.refreshDevices();
  } catch (e) {
    messenger.say(problem(e));
  }
}

/// What to call a device on screen. A device from before the app named its own
/// devices signed in as "flutter"; until it says its name, it is called by what it is.
String labelFor(DeviceInfo device) {
  final name = device.name.trim();
  if (name.isNotEmpty && name.toLowerCase() != 'flutter') return name;
  return switch (device.kind ?? device.platform ?? '') {
    'browser' || 'web' => 'A browser',
    'desktop' || 'linux' || 'windows' || 'macos' => 'A computer',
    'tablet' => 'A tablet',
    _ => 'A phone',
  };
}

IconData iconFor(DeviceInfo device) => switch (device.kind ?? device.platform ?? '') {
      'browser' || 'web' => Icons.language,
      'desktop' || 'linux' || 'windows' || 'macos' => Icons.computer_outlined,
      'tablet' => Icons.tablet_mac,
      'android' || 'phone' || 'ios' => Icons.smartphone,
      _ => Icons.devices_other,
    };

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
        tooltip: somewhereElse ? 'Playing on ${labelFor(there)}' : 'Where it plays',
        onPressed: () => showDevices(context),
      );
    }
    return TextButton.icon(
      onPressed: () => showDevices(context),
      icon: Icon(
          somewhereElse ? Icons.speaker_group : Icons.speaker_group_outlined,
          size: size,
          color: somewhereElse ? scheme.primary : null),
      label: Text(somewhereElse ? labelFor(there) : 'This device',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: somewhereElse ? TextStyle(color: scheme.primary) : null),
    );
  }
}
