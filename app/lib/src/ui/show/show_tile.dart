// The show in the booth's top band: a small picture of what the stage is showing,
// what is on in words, what the hands hold, MilkDrop's preset, and the few hands a
// glance wants — the scene either way, hold, a hit, the blackout — with the way to the
// show's own page (K) for everything else, the stage full screen here, or in a window
// of its own.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/app_state.dart';
import '../../state/booth/booth.dart';
import '../../state/show/milk_feed.dart';
import '../../state/show/show_engine.dart';
import '../../state/show/show_state.dart';
import '../../worker/tools.dart';
import '../booth/desk/console.dart';
import 'milk_page.dart';
import 'native_stage.dart';
import 'scene.dart';
import 'show_debug.dart';
import 'stage_preview.dart';
import 'stage_kit.dart';
import 'stage_page.dart';
import 'stage_pop_out_none.dart' if (dart.library.io) 'stage_pop_out_io.dart';

/// Bumped by the V key: the room shows the show, or goes back.
final showViewToggles = ValueNotifier<int>(0);

class ShowTile extends StatefulWidget {
  const ShowTile({super.key, required this.booth, this.onRig});
  final Booth booth;

  /// Opens the show's own page, where there is one.
  final VoidCallback? onRig;

  @override
  State<ShowTile> createState() => _ShowTileState();
}

class _ShowTileState extends State<ShowTile> {
  StageKit? _kit;
  String? _trouble;

  /// Which stage draws the small picture, and how fast: for the line under it.
  final _info = ValueNotifier<StageInfo>(StageInfo.none);

  /// No ffmpeg on this computer: said under the hands, with what to do about it.
  bool _noFfmpeg = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _info.dispose();
    super.dispose();
  }

  /// The performer's offset for this screen: see ShowEngine.offsetMs.
  static const _kOffset = 'muse.show.offsetMs';

  Future<void> _load() async {
    try {
      await ShowDebug.load();
      final prefs = await SharedPreferences.getInstance();
      widget.booth.show.offsetMs = prefs.getInt(_kOffset) ?? 0;
      await widget.booth.show.ready();
      final ffmpeg = await Tools.hasFfmpeg();
      if (mounted && !ffmpeg) setState(() => _noFfmpeg = true);
      final kit = await StageKit.load();
      widget.booth.show.director.scenes = kit.book.metas;
      widget.booth.show.looks = kit.book.looks;
      if (mounted) setState(() => _kit = kit);
    } catch (e) {
      if (mounted) setState(() => _trouble = '$e');
    }
  }

  /// What the hands hold, in a few words.
  String _held(ShowEngine show) {
    final book = _kit?.book;
    return [
      for (final h in show.holds)
        switch (h) {
          ShowHold.look => show.faveOn != null ? 'a favourite' : (show.milkOnly ? 'MilkDrop alone' : (book?[show.state.scene]?.name ?? 'the scene')),
          ShowHold.ground => 'MilkDrop under',
          ShowHold.effect => 'an effect',
          ShowHold.preset => 'the preset',
          ShowHold.pending => 'one waiting',
        },
    ].join(', ');
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
                      : StagePreview(feed: show, book: kit.book, programs: kit.programs, scale: 0.4, info: _info),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 200,
          child: ListenableBuilder(
            listenable: Listenable.merge([show, MilkFeed.shared.director]),
            builder: (context, _) {
              final st = show.state;
              final m = st.master;
              final c = show.combo;
              final held = _held(show);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(kit?.book[st.scene]?.name ?? st.scene ?? '—',
                      style: TextStyle(color: Console.ink, fontWeight: FontWeight.w700, fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ValueListenableBuilder<StageInfo>(
                    valueListenable: _info,
                    builder: (context, info, _) => Text(
                      [
                        if (c != null && c.style != 'raw') c.style,
                        if (m.section != null) m.section!,
                        if (m.dropBeatsAway != null && m.dropBeatsAway! > 0) 'drop in ${m.dropBeatsAway!.ceil()}',
                        '${info.word}${info.parked ? ' parked' : ''}${info.fps > 0 ? ' ${info.fps.round()}' : ''}',
                      ].join(' · '),
                      style: TextStyle(color: Console.quiet, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (held.isNotEmpty)
                    Row(children: [
                      Expanded(
                        child: Text('held: $held', style: TextStyle(color: Console.a, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                      Pad(label: 'LET GO', height: 20, colour: Console.a, tooltip: 'Every hold let go: the director has it all again', onTap: show.letGoAll),
                    ]),
                  const SizedBox(height: 4),
                  // MilkDrop: the preset on, and the hands on it — where the helper is here.
                  if (MilkFeed.shared.available)
                    ListenableBuilder(
                      listenable: MilkFeed.shared,
                      builder: (context, _) {
                        final milk = MilkFeed.shared;
                        return Row(
                          children: [
                            Expanded(
                              child: Tooltip(
                                message: 'MilkDrop\'s presets: the SHOW page (K), MILKDROP',
                                child: Text(
                                  milk.running ? (milk.presetName ?? 'MilkDrop…') : 'MilkDrop off',
                                  style: TextStyle(color: milk.running ? Console.ink : Console.quiet, fontSize: 12),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            Pad(
                                icon: Icons.casino_outlined,
                                width: 22,
                                height: 22,
                                colour: Console.quiet,
                                tooltip: 'Another preset',
                                onTap: () {
                                  if (!milk.running) unawaited(milk.start());
                                  milk.director.random(byHand: true);
                                }),
                            const SizedBox(width: 2),
                            const MilkHoldPad(size: 22),
                          ],
                        );
                      },
                    ),
                  if (_noFfmpeg || MilkFeed.shared.pcm.noFfmpeg)
                    Tooltip(
                      message: 'MilkDrop hears the records through ffmpeg, and the camera is read through it. ${Tools.ffmpegHint}',
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded, size: 14, color: Color(0xffe0a030)),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text('No ffmpeg: MilkDrop is deaf, no camera',
                                style: TextStyle(color: Console.quiet, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    ),
                  const Spacer(),
                  Row(
                    children: [
                      Pad(icon: Icons.chevron_left, width: 30, height: 30, colour: Console.ink, tooltip: 'The scene before', onTap: show.previousScene),
                      const SizedBox(width: 4),
                      Pad(icon: Icons.chevron_right, width: 30, height: 30, colour: Console.ink, tooltip: 'The next scene', onTap: show.nextScene),
                      const SizedBox(width: 4),
                      Pad(
                        icon: show.sceneHeld ? Icons.lock : Icons.lock_open,
                        width: 30,
                        height: 30,
                        lit: show.sceneHeld,
                        colour: Console.ink,
                        tooltip: show.sceneHeld ? 'Held — let the show change again' : 'Hold what is on until you let go',
                        onTap: () => show.holdScene(!show.sceneHeld),
                      ),
                      const SizedBox(width: 4),
                      Pad(icon: Icons.flash_on, width: 30, height: 30, colour: Console.ink, tooltip: 'Hit', onTap: show.hit),
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
                  if (widget.onRig != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: _Button(
                          icon: Icons.tune,
                          label: 'The show (K)',
                          tip: 'The show\'s own page: how often everything comes, each scene\'s looks, the favourites, MilkDrop, the settings',
                          onTap: widget.onRig),
                    )
                  else if (MilkFeed.shared.available)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: _Button(
                        icon: Icons.blur_on,
                        label: 'MilkDrop presets',
                        tip: 'Browse, favourite, make and edit MilkDrop presets',
                        onTap: () => openMilkPage(context, widget.booth),
                      ),
                    ),
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

/// The performer's offset for this screen (ShowEngine.offsetMs), asked for in a
/// dialog and kept — the tile's, and the show page's.
Future<void> showTileOffsetDialog(BuildContext context, Booth booth) async {
  const kOffset = 'muse.show.offsetMs';
  {
    final show = booth.show;
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
    await prefs.setInt(kOffset, ms);
  }
}
