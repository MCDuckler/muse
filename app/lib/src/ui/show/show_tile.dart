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
import '../../state/show/milk_feed.dart';
import '../../state/show/show_state.dart';
import '../../worker/tools.dart';
import '../booth/desk/console.dart';
import 'milk_page.dart';
import 'native_stage.dart';
import 'scene.dart';
import 'show_dance.dart' show DanceModels;
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

  /// Opens the show's own page (the rig), where there is one.
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

  /// Who dances in the dancer scenes: the pool's (show_pool.dart), and from there
  /// ShowMacros.dancer.
  void _setDancer(String id) {
    final show = widget.booth.show;
    final mix = id == DanceModels.mix;
    show.setPool(show.pool.copyWith(dancer: mix ? null : id, clearDancer: mix));
  }

  /// A dancer switched off in the menu: never in a mix, as lead or in a troupe.
  void _setDancerOff(String id, bool off) {
    final show = widget.booth.show;
    var pool = show.pool.withOff('dancer.$id', off);
    // The one chosen to dance alone, switched off: back to the mix.
    if (off && pool.dancer == id) pool = pool.copyWith(clearDancer: true);
    show.setPool(pool);
  }

  /// A scene (a look) switched off in the menu: see ShowDirector.off.
  void _setSceneOff(String id, bool off) {
    final show = widget.booth.show;
    show.setPool(show.pool.withOff('look.$id', off));
    // Turned off while it is on: on to the next one now, not at the next section.
    if (off && show.state.scene == id) show.nextScene();
  }

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

  Future<void> _offset(BuildContext context) => showTileOffsetDialog(context, widget.booth);

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
                      Expanded(
                        // The scene's name is the list of them: any one, straight to it.
                        child: kit == null
                            ? Text(scene?.name ?? '—', style: TextStyle(color: Console.ink, fontWeight: FontWeight.w700, fontSize: 15))
                            : PopupMenuButton<String>(
                                tooltip: 'Choose a scene, or turn scenes off',
                                onSelected: show.chooseScene,
                                itemBuilder: (context) => [
                                  const PopupMenuItem<String>(
                                    enabled: false,
                                    height: 28,
                                    child: Text('A name puts it on · a switch off keeps the director away from it', style: TextStyle(fontSize: 11)),
                                  ),
                                  for (final s in kit.book.scenes.values.toList()..sort((a, b) => a.name.compareTo(b.name)))
                                    PopupMenuItem<String>(
                                      value: s.id,
                                      child: StatefulBuilder(builder: (context, setItem) {
                                        final isOn = !show.director.off.contains(s.id);
                                        return Row(
                                          children: [
                                            SizedBox(width: 22, child: s.id == st.scene ? const Icon(Icons.play_arrow, size: 16) : null),
                                            Expanded(
                                              child: Text(
                                                s.meta.needs.contains('camera') ? '${s.name} (camera)' : s.name,
                                                style: TextStyle(color: isOn ? null : Theme.of(context).disabledColor),
                                              ),
                                            ),
                                            Tooltip(
                                              message: isOn ? 'On: the director may choose it' : 'Off: the director passes it by',
                                              child: Switch(
                                                value: isOn,
                                                onChanged: (v) {
                                                  _setSceneOff(s.id, !v);
                                                  setItem(() {});
                                                },
                                              ),
                                            ),
                                          ],
                                        );
                                      }),
                                    ),
                                ],
                                child: Row(
                                  children: [
                                    Flexible(
                                      child: Text(scene?.name ?? '—',
                                          style: TextStyle(color: Console.ink, fontWeight: FontWeight.w700, fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
                                    ),
                                    Icon(Icons.arrow_drop_down, size: 18, color: Console.quiet),
                                  ],
                                ),
                              ),
                      ),
                      // On a dancer scene: who dances.
                      if (st.scene?.startsWith('dance-') ?? false)
                        PopupMenuButton<String>(
                          tooltip: 'Who dances: ${DanceModels.all.where((d) => d.$1 == st.macros.dancer).firstOrNull?.$2 ?? 'a mix, each record its own'}',
                          onSelected: _setDancer,
                          itemBuilder: (context) => [
                            const PopupMenuItem<String>(
                              enabled: false,
                              height: 28,
                              child: Text('A name dances alone · a switch off keeps them out of the mix', style: TextStyle(fontSize: 11)),
                            ),
                            CheckedPopupMenuItem<String>(
                              value: DanceModels.mix,
                              checked: (st.macros.dancer ?? DanceModels.mix) == DanceModels.mix,
                              child: const Text('Mix — each record its own'),
                            ),
                            for (final (id, name) in DanceModels.all)
                              PopupMenuItem<String>(
                                value: id,
                                child: StatefulBuilder(builder: (context, setItem) {
                                  final isOn = !show.macros.dancersOff.contains(id);
                                  return Row(
                                    children: [
                                      SizedBox(width: 22, child: st.macros.dancer == id ? const Icon(Icons.check, size: 16) : null),
                                      Expanded(
                                        child: Text(name, style: TextStyle(color: isOn ? null : Theme.of(context).disabledColor)),
                                      ),
                                      Tooltip(
                                        message: isOn ? 'On: may dance in the mix' : 'Off: never in the mix',
                                        child: Switch(
                                          value: isOn,
                                          onChanged: (v) {
                                            _setDancerOff(id, !v);
                                            setItem(() {});
                                          },
                                        ),
                                      ),
                                    ],
                                  );
                                }),
                              ),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: Icon(Icons.accessibility_new, size: 18, color: Console.quiet),
                          ),
                        ),
                      Pad(
                        icon: show.sceneHeld ? Icons.lock : Icons.lock_open,
                        width: 26,
                        height: 26,
                        lit: show.sceneHeld,
                        colour: Console.quiet,
                        tooltip: show.sceneHeld ? 'This scene is held — let the director choose again' : 'Hold this scene: the stage stays on it, the arrows still change it',
                        onTap: () => show.holdScene(!show.sceneHeld),
                      ),
                      Pad(icon: Icons.timer_outlined, width: 26, height: 26, colour: Console.quiet, tooltip: 'The picture against the sound', onTap: () => _offset(context)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  ValueListenableBuilder<StageInfo>(
                    valueListenable: _info,
                    builder: (context, info, _) => Text(
                      [
                        if (m.section != null) m.section!,
                        if (m.dropBeatsAway != null && m.dropBeatsAway! > 0) 'drop in ${m.dropBeatsAway!.ceil()}',
                        if (st.mix.on) 'mix ${(st.mix.k * 100).round()}%',
                        // Which stage draws this picture: the native one, or Flutter's —
                        // and how fast. The debug pad says why, over the picture.
                        '${info.word}${info.parked ? ' parked' : ''}${info.fps > 0 ? ' ${info.fps.round()}' : ''}',
                      ].join(' · '),
                      style: TextStyle(color: Console.quiet, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // MilkDrop: the preset on, and the hands on it — where the helper is here.
                  if (MilkFeed.shared.available)
                    ListenableBuilder(
                      listenable: MilkFeed.shared,
                      builder: (context, _) {
                        final milk = MilkFeed.shared;
                        final d = milk.director;
                        final only = show.milkOnly;
                        return Row(
                          children: [
                            Expanded(
                              child: Text(
                                milk.running ? (milk.presetName ?? 'MilkDrop…') : 'MilkDrop off',
                                style: TextStyle(color: milk.running ? Console.ink : Console.quiet, fontSize: 12),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Pad(
                              icon: Icons.filter_center_focus,
                              width: 22,
                              height: 22,
                              lit: only,
                              colour: Console.quiet,
                              tooltip: only ? 'Only MilkDrop — back to the scenes' : 'Only MilkDrop: the stage held on it, ‹ › on its presets',
                              onTap: () => show.setMilkOnly(!only),
                            ),
                            const SizedBox(width: 2),
                            Pad(
                              icon: Icons.layers_outlined,
                              width: 22,
                              height: 22,
                              lit: st.macros.milkUnder,
                              colour: Console.quiet,
                              tooltip: st.macros.milkUnder
                                  ? 'MilkDrop under the scenes, ${ShowMacros.milkMixes[st.macros.milkMix % ShowMacros.milkMixes.length].$1} — off; hold for the next way'
                                  : 'MilkDrop under every scene',
                              onTap: () => show.setMacros(show.macros.copyWith(milkUnder: !show.macros.milkUnder)),
                              onLongPress: () => show.setMacros(show.macros.copyWith(milkUnder: true, milkMix: (show.macros.milkMix + 1) % ShowMacros.milkMixes.length)),
                            ),
                            const SizedBox(width: 2),
                            Pad(icon: Icons.casino_outlined, width: 22, height: 22, colour: Console.quiet, tooltip: 'Another preset', onTap: () {
                              if (!milk.running) unawaited(milk.start());
                              d.random(byHand: true);
                            }),
                            const SizedBox(width: 2),
                            Pad(
                              icon: d.locked ? Icons.lock : Icons.lock_open,
                              width: 22,
                              height: 22,
                              lit: d.locked,
                              colour: Console.quiet,
                              tooltip: d.locked ? 'Held' : 'Hold this preset',
                              onTap: () => d.set(locked: !d.locked),
                            ),
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
                            tooltip: cam.running
                                ? 'The camera is on — off'
                                : cam.trouble != null
                                    ? 'The room\'s camera on — last time: ${cam.trouble}'
                                    : 'The room\'s camera on (the camera scenes need it)',
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
                      const SizedBox(width: 4),
                      ValueListenableBuilder<bool>(
                        valueListenable: ShowDebug.on,
                        builder: (context, on, _) => Pad(
                          icon: Icons.bug_report_outlined,
                          width: 30,
                          height: 30,
                          lit: on,
                          colour: Console.ink,
                          tooltip: on
                              ? 'The debug words over every stage — off'
                              : 'Debug words over every stage: which renderer draws it (native or Flutter), why, how fast (I on the stage page)',
                          onTap: ShowDebug.toggle,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (MilkFeed.shared.available)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: _Button(
                        icon: Icons.blur_on,
                        label: 'MilkDrop presets',
                        tip: 'Browse, favourite, make and edit MilkDrop presets',
                        onTap: () => openMilkPage(context, widget.booth),
                      ),
                    ),
                  if (widget.onRig != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: _Button(icon: Icons.tune, label: 'The rig', tip: 'The show\'s own page: its layers, its pool, the dancers (K)', onTap: widget.onRig),
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

