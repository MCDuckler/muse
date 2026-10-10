// The show in the booth's top band: a small picture of what the stage is showing,
// the director's word under it, and the hands — the scene either way, a hit, the
// blackout, the stage full screen here, or in a window of its own.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/app_state.dart';
import '../../state/booth/booth.dart';
import '../../state/show/camera_feed.dart';
import '../../state/show/show_state.dart';
import '../booth/desk/console.dart';
import 'show_canvas.dart';
import 'stage_kit.dart';
import 'stage_page.dart';
import 'stage_pop_out_none.dart' if (dart.library.io) 'stage_pop_out_io.dart';

/// Bumped by the V key: the room shows the show, or goes back.
final showViewToggles = ValueNotifier<int>(0);

class ShowTile extends StatefulWidget {
  const ShowTile({super.key, required this.booth});
  final Booth booth;

  @override
  State<ShowTile> createState() => _ShowTileState();
}

class _ShowTileState extends State<ShowTile> {
  StageKit? _kit;
  String? _trouble;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// The performer's offset for this screen: see ShowEngine.offsetMs.
  static const _kOffset = 'muse.show.offsetMs';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      widget.booth.show.offsetMs = prefs.getInt(_kOffset) ?? 0;
      final kit = await StageKit.load();
      widget.booth.show.director.scenes = kit.book.metas;
      if (mounted) setState(() => _kit = kit);
    } catch (e) {
      if (mounted) setState(() => _trouble = '$e');
    }
  }

  Future<void> _offset(BuildContext context) async {
    final show = widget.booth.show;
    var ms = show.offsetMs;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('The picture against the sound'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('A flash that lands after the kick wants the picture earlier; one before it, later. '
                  'A television over HDMI is usually 40 to 100 ms late.'),
              const SizedBox(height: 12),
              Text(ms == 0 ? 'As the deck says' : '${ms > 0 ? 'Later' : 'Earlier'} by ${ms.abs()} ms'),
              Slider(
                value: ms.toDouble(),
                min: -250,
                max: 250,
                divisions: 100,
                onChanged: (v) {
                  setState(() => ms = v.round());
                  show.offsetMs = ms;
                },
              ),
            ],
          ),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))],
        ),
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kOffset, ms);
  }

  @override
  Widget build(BuildContext context) {
    final kit = _kit;
    final show = widget.booth.show;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ColoredBox(
              color: Colors.black,
              child: _trouble != null
                  ? Center(child: Text('The stage could not load.\n$_trouble', style: TextStyle(color: Console.quiet)))
                  : kit == null
                      ? const SizedBox.shrink()
                      : ShowCanvas(feed: show, book: kit.book, programs: kit.programs, scale: 0.4, preview: true),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 200,
          child: ListenableBuilder(
            listenable: show,
            builder: (context, _) {
              final st = show.state;
              final m = st.master;
              final scene = kit?.book[st.scene];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(scene?.name ?? '—', style: TextStyle(color: Console.ink, fontWeight: FontWeight.w700, fontSize: 15))),
                      Pad(icon: Icons.timer_outlined, width: 26, height: 26, colour: Console.quiet, tooltip: 'The picture against the sound', onTap: () => _offset(context)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (m.section != null) m.section!,
                      if (m.dropBeatsAway != null && m.dropBeatsAway! > 0) 'drop in ${m.dropBeatsAway!.ceil()}',
                      if (st.mix.on) 'mix ${(st.mix.k * 100).round()}%',
                    ].join(' · '),
                    style: TextStyle(color: Console.quiet, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      Pad(icon: Icons.chevron_left, width: 30, height: 30, colour: Console.ink, tooltip: 'The scene before', onTap: show.previousScene),
                      const SizedBox(width: 4),
                      Pad(icon: Icons.chevron_right, width: 30, height: 30, colour: Console.ink, tooltip: 'The next scene', onTap: show.nextScene),
                      const SizedBox(width: 4),
                      Pad(icon: Icons.flash_on, width: 30, height: 30, colour: Console.ink, tooltip: 'Hit', onTap: show.hit),
                      const SizedBox(width: 4),
                      ListenableBuilder(
                        listenable: CameraFeed.shared,
                        builder: (context, _) {
                          final cam = CameraFeed.shared;
                          return Pad(
                            icon: cam.running ? Icons.videocam : Icons.videocam_off_outlined,
                            width: 30,
                            height: 30,
                            lit: cam.running,
                            colour: cam.running ? const Color(0xffe0302a) : Console.ink,
                            tooltip: cam.running ? 'The camera is on — off' : 'The room\'s camera on (the camera scenes need it)',
                            onTap: () {
                              if (cam.running) {
                                cam.pinned = false;
                                cam.stop();
                              } else {
                                cam.pinned = true;
                                unawaited(cam.start());
                              }
                            },
                          );
                        },
                      ),
                      const SizedBox(width: 4),
                      Pad(
                        icon: Icons.dark_mode_outlined,
                        width: 30,
                        height: 30,
                        lit: st.macros.blackout,
                        colour: Console.ink,
                        tooltip: 'Blackout',
                        onTap: () => show.setMacros(show.macros.copyWith(blackout: !show.macros.blackout)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: _Button(
                          icon: Icons.fullscreen,
                          label: 'Stage',
                          tip: 'The stage over this window (⇧V)',
                          onTap: kit == null ? null : () => openStagePage(context, widget.booth),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: _Button(
                          icon: Icons.open_in_new,
                          label: 'Pop out',
                          tip: 'The stage in a window of its own, for the other screen (⌥V)',
                          onTap: canPopOutStage ? () => unawaited(popOutStage(context.read<AppState>().boardLink)) : null,
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({required this.icon, required this.label, required this.tip, this.onTap});
  final IconData icon;
  final String label, tip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tip,
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 16),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            foregroundColor: Console.ink,
            side: BorderSide(color: Console.quiet.withValues(alpha: 0.5)),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            visualDensity: VisualDensity.compact,
          ),
        ),
      );
}

/// The state line's words for a frame, for a test.
String showTileWords(ShowState st) => [st.scene ?? '—', st.master.section ?? ''].join(' ');
