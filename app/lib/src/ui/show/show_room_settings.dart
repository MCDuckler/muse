// SETTINGS: the picture's finish over every scene and how strong the blend is (kept,
// and in a set); this machine's — the quality, the picture against the sound, the
// room's camera, the debug words; and the stage's own numbers and log.
part of 'show_room.dart';

class _SettingsTab extends StatelessWidget {
  const _SettingsTab({required this.show, required this.info, required this.booth});
  final ShowEngine show;
  final ValueNotifier<StageInfo> info;
  final Booth booth;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: show,
        builder: (context, _) {
          final rig = show.state.rig;
          final f = show.finish ?? rig.finish;
          final mineFinish = show.finish != null;
          Widget knob(String label, double v, double max, String tip, RigFinish Function(double) set) => Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Knob(
                    value: v,
                    min: 0,
                    max: max,
                    rest: 0,
                    bipolar: false,
                    size: 30,
                    label: label,
                    tooltip: '$tip: ${(v / max * 100).round()} %',
                    onChanged: (x) => show.setFinish(set(x))),
              );
          return ListView(children: [
            _Head('THE FINISH',
                hint: mineFinish ? 'yours over every scene · kept, and in a set' : 'each scene\'s own · a knob turned makes it yours over every scene',
                trailing: [
                  if (mineFinish)
                    IntrinsicWidth(child: Pad(label: 'EACH SCENE\'S OWN', height: 22, colour: Console.quiet, onTap: () => show.setFinish(null))),
                ]),
            _Line(children: [
              knob('TRAILS', f.trails, 0.9, 'How much of last frame lingers', (x) => f.copyWith(trails: x)),
              knob('BLOOM', f.bloom, 1.5, 'The glow round bright things', (x) => f.copyWith(bloom: x)),
              knob('TONE', f.tone, 1, 'The film curve (0 is the picture as drawn)', (x) => f.copyWith(tone: x)),
              knob('GRAIN', f.grain, 1, 'Film grain', (x) => f.copyWith(grain: x)),
              knob('VIGNETTE', f.vignette, 1, 'The corners darkened', (x) => f.copyWith(vignette: x)),
              _Word(
                label: 'TITLE & LYRICS',
                lit: f.title || f.lyrics,
                tooltip: 'The record\'s title and the line being sung, over the stage',
                onTap: () => show.setFinish(f.copyWith(title: !(f.title || f.lyrics), lyrics: !(f.title || f.lyrics))),
              ),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              SizedBox(width: 210, child: Text('HOW STRONG THE BLEND', style: Console.label(9, color: Console.ink))),
              Expanded(child: Slider(value: show.blendStrength, onChanged: show.setBlendStrength, padding: const EdgeInsets.symmetric(horizontal: 12))),
              SizedBox(width: 44, child: Text('${(show.blendStrength * 100).round()} %', textAlign: TextAlign.right, style: Console.label(9))),
            ]),
            const _Head('THIS MACHINE', hint: 'not in a set'),
            Text('QUALITY', style: Console.label(9, color: Console.ink)),
            const SizedBox(height: 4),
            Wrap(children: [
              for (final t in QualityPool.tiers)
                _Word(
                  label: t.toUpperCase(),
                  lit: show.pool.tier == t,
                  tooltip: switch (t) {
                    'low' => 'A slow machine: the picture at 60 %, fewer birds, no big companies',
                    'mid' => 'The picture at 80 %, three quarters of the birds',
                    'high' => 'Everything, at full size',
                    _ => 'As the stage finds it can: full size (the native stage scales itself down when frames run late)',
                  },
                  onTap: () => show.setPool(show.pool.copyWith(tier: t)),
                ),
            ]),
            Row(children: [
              Expanded(child: Text('lower the quality when frames run late (and raise it back)', style: TextStyle(fontSize: 12, color: Console.ink))),
              Tooltip(
                message: show.pool.adapt
                    ? "On: the stages trade the picture's size for their frames, and back"
                    : "Off: the picture stays at the tier's size whatever the frames — smooth or not",
                child: Switch(value: show.pool.adapt, onChanged: show.setAdapt),
              ),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: Text(show.offsetMs == 0 ? 'the picture against the sound: as the deck says' : 'the picture against the sound: ${show.offsetMs > 0 ? 'later' : 'earlier'} by ${show.offsetMs.abs()} ms',
                    style: TextStyle(fontSize: 12, color: Console.ink)),
              ),
              IntrinsicWidth(
                child: Pad(
                    label: 'SET IT…', height: 24, colour: Console.quiet, tooltip: 'The performer\'s offset for this screen', onTap: () => showTileOffsetDialog(context, booth)),
              ),
            ]),
            const SizedBox(height: 6),
            ListenableBuilder(
              listenable: CameraFeed.shared,
              builder: (context, _) {
                final cam = CameraFeed.shared;
                return Row(children: [
                  Expanded(
                    child: Text(
                      cam.running
                          ? 'the room\'s camera is on (the camera background and the camera scenes)'
                          : cam.trouble != null
                              ? 'the room\'s camera is off — last time: ${cam.trouble}'
                              : 'the room\'s camera is off (the camera background and the camera scenes need it)',
                      style: TextStyle(fontSize: 12, color: Console.ink),
                    ),
                  ),
                  Switch(
                    value: cam.running,
                    onChanged: (v) {
                      if (!v) {
                        cam.pinned = false;
                        cam.stop();
                      } else {
                        cam.pinned = true;
                        unawaited(cam.start());
                      }
                    },
                  ),
                ]);
              },
            ),
            ValueListenableBuilder<bool>(
              valueListenable: ShowDebug.on,
              builder: (context, on, _) => Row(children: [
                Expanded(child: Text('debug words over every stage (I on the stage page)', style: TextStyle(fontSize: 12, color: Console.ink))),
                Switch(value: on, onChanged: (v) => unawaited(ShowDebug.set(v))),
              ]),
            ),
            const Divider(height: 20),
            _StageNumbers(info: info),
          ]);
        },
      );
}

/// The stage's own numbers and its log.
class _StageNumbers extends StatelessWidget {
  const _StageNumbers({required this.info});
  final ValueNotifier<StageInfo> info;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<StageInfo>(
        valueListenable: info,
        builder: (context, i, _) => ValueListenableBuilder<List<String>>(
          valueListenable: ShowDebug.flips,
          builder: (context, flips, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('THIS PAGE\'S PICTURE', style: Console.label(10, color: Console.ink)),
              const SizedBox(height: 4),
              Text(
                [
                  'renderer: ${i.word}${i.parked ? ' (parked under the Flutter stage)' : ''}',
                  if (i.fps > 0)
                    '${i.fps.toStringAsFixed(1)} fps${i.native ? ' · ${i.ms.toStringAsFixed(1)} ms a frame, worst ${i.worstMs.toStringAsFixed(1)}' : ''}',
                  if (i.width > 0)
                    '${i.width}×${i.height}${i.native && i.workWidth > 0 ? ' → work ${i.workWidth}×${i.workHeight} (auto ×${i.autoScale.toStringAsFixed(2)})' : ''}',
                  if (i.native) i.float ? 'float targets' : '8-bit targets',
                  if (i.why.isNotEmpty) 'why not native: ${i.why}',
                ].join('\n'),
                style: Mag.typewriter(11, color: Console.ink),
              ),
              const SizedBox(height: 10),
              Text('STAGE LOG', style: Console.label(10, color: Console.ink)),
              const SizedBox(height: 4),
              Text(flips.isEmpty ? 'none yet' : flips.join('\n'), style: Mag.typewriter(11, color: Console.quiet)),
            ],
          ),
        ),
      );
}
