// The moves: every move in a dancer's bank, browsed and watched — a strip of poses
// for each, a viewer that loops one front on at its own tempo or the record's, and
// a switch and a star per move for the pool (show_pool.dart: `move.<id>`), which the
// choreography reads once it is wired to the pool (plan step 3).
//
// Everything here draws on the CPU through the same bodies the Flutter stage uses
// (show_dance_draw.dart): a few hundred pixels across, a move costs a millisecond.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../state/show/show_engine.dart';
import '../../state/show/show_pool.dart' show MovePool;
import '../booth/desk/console.dart';
import 'show_dance.dart' show DanceAssets, DanceClock, DanceFrame, DanceModels, DanceShot, DanceTroupe;
import 'show_dance_draw.dart';
import 'show_dance_rig.dart';

/// A line of pads, scrolled sideways where it is long (a pad in a column or a wrap
/// takes the whole width; in a row it takes its word's).
class _Line extends StatelessWidget {
  const _Line({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: children),
      );
}

/// How the viewer's body is drawn.
enum MoveLook { textured, chrome, silhouette }

DanceLook3 _look3(MoveLook l) => switch (l) {
      MoveLook.textured => const DanceLook3(
          key: V3(-0.35, -0.8, 0.65),
          keyColor: Color(0xfffffaf2),
          keyK: 0.55,
          fill: Color(0xffc8ccd4),
          fillK: 0.3,
          ambient: 0.5,
          rimK: 0,
        ),
      MoveLook.chrome => const DanceLook3(chrome: true, keyColor: Colors.white, textured: false, rimK: 0.3),
      MoveLook.silhouette => const DanceLook3(flat: Color(0xfff3f2ee), textured: false, shadeFlat: false),
    };

/// How much bigger a model is drawn, so every dancer stands about a person's height.
double _scaleOf(DanceRig rig) => rig.height > 0.3 ? (1.75 / rig.height).clamp(0.8, 1.2) : 1;

/// One move looping on one body, front on.
class MoveViewer extends StatefulWidget {
  const MoveViewer({
    super.key,
    required this.model,
    required this.move,
    this.bpm,
    this.speed = 1,
    this.look = MoveLook.textured,
    this.playing = true,
    this.mirror = false,
    this.onBeat,
  });

  final String model;
  final DanceMove? move;

  /// The tempo to dance at, in track beats a minute (the record's, say); the
  /// capture's own when null. The capture dances at half or double time when the
  /// tempo is far from its own, as on the stage.
  final double? bpm;
  final double speed;
  final MoveLook look;
  final bool playing, mirror;

  /// Told the beat in the loop, 0..move.beats, as it plays (for a scrub bar).
  final void Function(double beat)? onBeat;

  @override
  State<MoveViewer> createState() => _MoveViewerState();
}

class _MoveViewerState extends State<MoveViewer> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _tick = ValueNotifier<int>(0);
  Duration? _last;
  double _beat = 0;
  DanceBody? _body;
  String? _bodyModel;
  DancePose? _pose;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_frame)..start();
    _ready();
  }

  void _ready() {
    final a = DanceAssets.of(widget.model);
    if (!a.ready) unawaited(a.loaded.then((_) => mounted ? setState(() {}) : null));
  }

  @override
  void didUpdateWidget(MoveViewer old) {
    super.didUpdateWidget(old);
    if (old.model != widget.model) _ready();
    if (old.move?.id != widget.move?.id) _beat = 0;
  }

  void _frame(Duration elapsed) {
    final last = _last;
    _last = elapsed;
    final move = widget.move;
    if (move == null) return;
    if (widget.playing && last != null) {
      final dt = ((elapsed - last).inMicroseconds / 1e6).clamp(0.0, 0.25);
      final bpm = widget.bpm;
      final perSecond = bpm == null ? move.bpm / 60 : bpm / 60 * DanceClock.rate(bpm, move.bpm);
      _beat = (_beat + dt * perSecond * widget.speed) % move.beats;
      widget.onBeat?.call(_beat);
    }
    _tick.value++;
  }

  /// The loop moved to [beat] by hand.
  void seek(double beat) {
    final move = widget.move;
    if (move == null) return;
    _beat = beat.clamp(0.0, move.beats.toDouble());
    _tick.value++;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _body?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = DanceAssets.of(widget.model);
    final rig = a.rig, skin = a.skin;
    if (rig == null || skin == null || widget.move == null) {
      return ColoredBox(
        color: const Color(0xff0a0a0c),
        child: Center(child: Text(widget.move == null ? 'Pick a move' : 'Loading ${widget.model}…', style: TextStyle(color: Console.quiet, fontSize: 12))),
      );
    }
    if (_body == null || _bodyModel != widget.model) {
      _body?.dispose();
      _body = DanceBody(rig.meshes.first, skin);
      _bodyModel = widget.model;
      _pose = DancePose(rig.bones);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CustomPaint(
        painter: _MovePainter(rig, _body!, _pose!, widget.move!, () => _beat, widget.look, widget.mirror, _tick),
        size: Size.infinite,
      ),
    );
  }
}

class _MovePainter extends CustomPainter {
  _MovePainter(this.rig, this.body, this.pose, this.move, this.beat, this.look, this.mirror, Listenable tick) : super(repaint: tick);
  final DanceRig rig;
  final DanceBody body;
  final DancePose pose;
  final DanceMove move;
  final double Function() beat;
  final MoveLook look;
  final bool mirror;

  @override
  void paint(Canvas c, Size size) {
    final paper = look == MoveLook.silhouette ? const Color(0xff050505) : const Color(0xff0a0a0c);
    c.drawRect(Offset.zero & size, Paint()..color = paper);
    if (look != MoveLook.silhouette) {
      c.drawRect(
        Offset.zero & size,
        Paint()..shader = ui.Gradient.linear(Offset(0, size.height * 0.55), Offset(0, size.height), [const Color(0x00000000), const Color(0xff16161c)]),
      );
    }
    rig.sample(move, beat() % move.beats, pose);
    body.pose(rig, pose);
    body.place(DanceSpot(scale: _scaleOf(rig), mirror: mirror));
    final cam = DanceFrame.of(DanceShot.front, DanceTroupe.solo).cam(size);
    body.begin();
    if (look != MoveLook.silhouette) body.floorShadow(c, cam, const V3(-0.4, -0.6, 1.0), const Color(0x55000000));
    body.draw(c, cam, _look3(look), twoSided: true);
  }

  @override
  bool shouldRepaint(_MovePainter old) => true;
}

/// A move as a strip of poses across its loop, in silhouette: drawn once and kept.
class MoveStrip extends StatelessWidget {
  const MoveStrip({super.key, required this.model, required this.move, this.poses = 6, this.width = 192, this.height = 56});
  final String model;
  final DanceMove move;
  final int poses;
  final double width, height;

  static final _kept = <String, ui.Image>{};
  static DanceBody? _body;
  static String? _bodyModel;

  /// Forgotten (a model changed, a test).
  static void clear() {
    for (final i in _kept.values) {
      i.dispose();
    }
    _kept.clear();
    _body?.dispose();
    _body = null;
    _bodyModel = null;
  }

  ui.Image? _image(DanceRig rig, ui.Image skin) {
    final key = '$model|${move.id}|${width.round()}x${height.round()}|$poses';
    final had = _kept[key];
    if (had != null) return had;
    if (_body == null || _bodyModel != model) {
      _body?.dispose();
      final mesh = rig.meshes.length > 1 ? rig.meshes[1] : rig.meshes.first;
      _body = DanceBody(mesh, skin);
      _bodyModel = model;
    }
    final body = _body!;
    final pose = DancePose(rig.bones);
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final cell = Size(width / poses, height);
    final cam = DanceFrame.of(DanceShot.front, DanceTroupe.solo).cam(Size(cell.width * 1.6, cell.height));
    for (var i = 0; i < poses; i++) {
      rig.sample(move, move.beats * i / poses, pose);
      body.pose(rig, pose);
      body.place(DanceSpot(scale: _scaleOf(rig)));
      c.save();
      c.translate(cell.width * i - cell.width * 0.3, 0);
      c.clipRect(Rect.fromLTWH(cell.width * 0.3, 0, cell.width, cell.height));
      body.begin();
      body.draw(c, cam, const DanceLook3(flat: Color(0xffd8d8d8), textured: false, shadeFlat: false), twoSided: true);
      c.restore();
    }
    final pic = rec.endRecording();
    final img = pic.toImageSync(width.round(), height.round());
    pic.dispose();
    // A few hundred kept at most: the oldest go.
    if (_kept.length > 400) {
      final first = _kept.keys.first;
      _kept.remove(first)?.dispose();
    }
    return _kept[key] = img;
  }

  @override
  Widget build(BuildContext context) {
    final a = DanceAssets.of(model);
    final rig = a.rig, skin = a.skin;
    final img = rig == null || skin == null ? null : _image(rig, skin);
    return SizedBox(
      width: width,
      height: height,
      child: img == null ? const ColoredBox(color: Color(0xff101014)) : RawImage(image: img, fit: BoxFit.fill),
    );
  }
}

/// The browser: the model, the filters, the viewer, the list.
class MovesBrowser extends StatefulWidget {
  const MovesBrowser({super.key, required this.show});
  final ShowEngine show;

  @override
  State<MovesBrowser> createState() => _MovesBrowserState();
}

class _MovesBrowserState extends State<MovesBrowser> {
  String _model = DanceModels.all.first.$1;
  DanceMove? _move;
  DanceStyle? _style;
  DanceTier? _tier;
  bool _duets = false;
  String _search = '';
  MoveLook _look = MoveLook.textured;
  double _speed = 1;
  bool _playing = true, _mirror = false, _recordTempo = false;
  final _viewer = GlobalKey<_MoveViewerState>();
  double _beat = 0;

  @override
  void initState() {
    super.initState();
    final lead = widget.show.pool.dancer;
    if (lead != null && DanceModels.all.any((m) => m.$1 == lead)) _model = lead;
    _ready();
  }

  void _ready() {
    final a = DanceAssets.of(_model);
    if (!a.ready) unawaited(a.loaded.then((_) => mounted ? setState(() {}) : null));
  }

  List<DanceMove> _moves(DanceRig rig) {
    final out = [
      for (final m in rig.moves)
        if ((_style == null || m.style == _style) &&
            (_tier == null || m.tier == _tier) &&
            (!_duets || m.duo != null) &&
            (_duets || m.duo == null || m.part == 0) &&
            (_search.isEmpty || m.id.contains(_search) || m.style.name.contains(_search) || (m.duo?.contains(_search) ?? false)))
          m,
    ]..sort((a, b) {
        final s = a.style.index.compareTo(b.style.index);
        if (s != 0) return s;
        final t = a.tier.index.compareTo(b.tier.index);
        return t != 0 ? t : a.energy.compareTo(b.energy);
      });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final show = widget.show;
    final a = DanceAssets.of(_model);
    final rig = a.rig;
    final master = show.state.master;
    final bpm = _recordTempo && master.playing && (master.bpm ?? 0) > 1 ? master.bpm : null;
    return ListenableBuilder(
      listenable: show,
      builder: (context, _) {
        final pool = show.pool;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Text('THE MOVES', style: Console.label(10, color: Console.ink)),
              const SizedBox(width: 8),
              for (final (id, name) in DanceModels.all) ...[
                Pad(
                  label: name.split(' ').first.toUpperCase(),
                  height: 24,
                  lit: _model == id,
                  colour: Console.quiet,
                  tooltip: 'The bank of $name',
                  onTap: () => setState(() {
                    _model = id;
                    _move = null;
                    _ready();
                  }),
                ),
                const SizedBox(width: 4),
              ],
              const Spacer(),
              if (rig != null) Text('${rig.moves.length} moves', style: Console.label(9)),
            ]),
            const SizedBox(height: 6),
            // The viewer, and its hands.
            SizedBox(
              height: 200,
              child: MoveViewer(
                key: _viewer,
                model: _model,
                move: _move,
                bpm: bpm,
                speed: _speed,
                look: _look,
                playing: _playing,
                mirror: _mirror,
                onBeat: (b) => _beat = b,
              ),
            ),
            const SizedBox(height: 4),
            if (_move != null)
              Text('${_move!.id} · ${_move!.style.name} · ${_move!.bpm.round()} bpm · ${_move!.beats} beats · beat ${_beat.toStringAsFixed(1)}', style: Console.label(9)),
            const SizedBox(height: 4),
            _Line(children: [
              Pad(icon: _playing ? Icons.pause : Icons.play_arrow, width: 26, height: 24, colour: Console.quiet, tooltip: _playing ? 'Pause' : 'Play', onTap: () => setState(() => _playing = !_playing)),
              const SizedBox(width: 4),
              for (final sp in const [0.5, 1.0, 2.0]) ...[
                Pad(label: sp == 1 ? '×1' : (sp < 1 ? '×½' : '×2'), width: 30, height: 24, lit: _speed == sp, colour: Console.quiet, tooltip: 'Speed', onTap: () => setState(() => _speed = sp)),
                const SizedBox(width: 2),
              ],
              const SizedBox(width: 6),
              for (final l in MoveLook.values) ...[
                Pad(label: l.name.toUpperCase(), height: 24, lit: _look == l, colour: Console.quiet, tooltip: 'Drawn ${l.name}', onTap: () => setState(() => _look = l)),
                const SizedBox(width: 2),
              ],
              const SizedBox(width: 6),
              Pad(icon: Icons.flip, width: 26, height: 24, lit: _mirror, colour: Console.quiet, tooltip: 'Mirrored', onTap: () => setState(() => _mirror = !_mirror)),
              const SizedBox(width: 4),
              Pad(
                label: 'RECORD\'S TEMPO',
                height: 24,
                lit: _recordTempo,
                colour: master.playing ? Console.quiet : Console.faint,
                tooltip: master.playing ? 'Danced at the record\'s tempo (half or double time when far off)' : 'Nothing plays: the move\'s own tempo',
                onTap: () => setState(() => _recordTempo = !_recordTempo),
              ),
            ]),
            const SizedBox(height: 6),
            // The filters.
            _Line(children: [
              Pad(label: 'ALL', height: 22, lit: _style == null, colour: Console.quiet, onTap: () => setState(() => _style = null)),
              const SizedBox(width: 2),
              for (final s in DanceStyle.values) ...[
                Pad(label: s.name.toUpperCase(), height: 22, lit: _style == s, colour: Console.quiet, onTap: () => setState(() => _style = _style == s ? null : s)),
                const SizedBox(width: 2),
              ],
              const SizedBox(width: 8),
              for (final t in DanceTier.values) ...[
                Pad(label: t.name.toUpperCase(), height: 22, lit: _tier == t, colour: Console.quiet, tooltip: 'The ${t.name} tier', onTap: () => setState(() => _tier = _tier == t ? null : t)),
                const SizedBox(width: 2),
              ],
              const SizedBox(width: 8),
              Pad(label: 'DUETS', height: 22, lit: _duets, colour: Console.quiet, tooltip: 'Couples captured together', onTap: () => setState(() => _duets = !_duets)),
              const SizedBox(width: 8),
              SizedBox(
                width: 120,
                height: 24,
                child: TextField(
                  decoration: InputDecoration(isDense: true, hintText: 'find', hintStyle: TextStyle(color: Console.faint, fontSize: 11), contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4), border: const OutlineInputBorder()),
                  style: TextStyle(color: Console.ink, fontSize: 11),
                  onChanged: (v) => setState(() => _search = v.trim()),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Text('A strip plays the move above · ▷ makes the lead on the stage dance it next · the switch keeps it out of the dancing · the star makes it a favourite',
                style: TextStyle(fontSize: 10, color: Console.faint)),
            const SizedBox(height: 4),
            Expanded(
              child: rig == null
                  ? Center(child: Text('Loading $_model…', style: TextStyle(color: Console.quiet)))
                  : Builder(builder: (context) {
                      final moves = _moves(rig);
                      return ListView.builder(
                        itemCount: moves.length,
                        itemExtent: 64,
                        itemBuilder: (context, i) {
                          final m = moves[i];
                          final key = 'move.${m.id}';
                          final on = pool.isOn(key);
                          final star = pool.leanOf(key) > 1.5;
                          return Row(children: [
                            InkWell(
                              onTap: () => setState(() => _move = m),
                              child: Container(
                                decoration: BoxDecoration(border: Border.all(color: _move?.id == m.id ? Console.a : Console.line)),
                                child: MoveStrip(model: _model, move: m),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(m.id, style: TextStyle(color: on ? Console.ink : Console.faint, fontSize: 12)),
                                Text(
                                  '${m.style.name} · ${m.tier.name} · ${m.bpm.round()} bpm · ${m.beats} beats · energy ${m.energy.toStringAsFixed(1)}${m.duo != null ? ' · duet ${m.duo} ${m.part == 0 ? 'lead' : 'partner'}' : ''}',
                                  style: TextStyle(color: Console.quiet, fontSize: 10),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ]),
                            ),
                            Pad(
                              icon: Icons.play_circle_outline,
                              width: 26,
                              height: 24,
                              lit: MovePool.audition == m.id,
                              colour: Console.a,
                              tooltip: MovePool.audition == m.id ? 'Asked for: the lead dances it at the next slot' : 'Audition: the lead on the stage dances it at the next slot',
                              onTap: () => show.audition(m.id),
                            ),
                            const SizedBox(width: 2),
                            Pad(
                              icon: star ? Icons.star : Icons.star_border,
                              width: 26,
                              height: 24,
                              lit: star,
                              colour: Console.quiet,
                              tooltip: star ? 'A favourite — plain again' : 'A favourite: danced more',
                              onTap: () => show.setPool(pool.withLean(key, star ? 1 : 2)),
                            ),
                            Switch(value: on, onChanged: (v) => show.setPool(pool.withOff(key, !v))),
                          ]);
                        },
                      );
                    }),
            ),
          ],
        );
      },
    );
  }
}
