// A show with no booth: a made-up record, played for ever, as a feed. For the stage
// window on its own (`--stage --demo`), the perf tool, and the stage's shots.
//
// 128 BPM, a sixty-four-bar form that keeps coming round — eight bars of intro, a
// build, sixteen of drop, a breakdown with a voice in it, a build, a drop — with a
// pulse made to match: a kick on every beat, hats between, the bands up with the
// energy. The director runs over it as it would over a set, so what it shows is the
// show, not a demo of the shaders.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;

import 'camera_feed.dart';
import 'show_director.dart';
import 'show_dynamics.dart';
import 'show_events.dart';
import 'show_feed.dart';
import 'show_genome.dart';
import 'show_palette.dart';
import 'show_state.dart';

class DemoShowFeed extends ChangeNotifier implements ShowFeed {
  DemoShowFeed({this.bpm = 128, int seed = 3, List<SceneMeta> scenes = const []})
      : director = ShowDirector(scenes: scenes, seed: seed) {
    _state = _blank(DateTime.now());
  }

  final double bpm;
  final ShowDirector director;
  late ShowState _state;
  @override
  ShowState get state => _state;

  final _events = StreamController<ShowEvent>.broadcast(sync: true);
  @override
  Stream<ShowEvent> get events => _events.stream;

  Timer? _timer;
  DateTime? _began, _last;
  ShowMacros macros = ShowMacros.none;

  /// The records, one after the other, each with its own colour and key.
  static const _records = [
    ('Nothing Left To Learn', 'WetOwl', '8A', 0xffd04070),
    ('Glass Harbour', 'Ilse Varga', '11B', 0xff2060c0),
    ('Kessel Run', 'Tomás Nkemelu', '2A', 0xff30b080),
    ('Low Orbit', 'Saoirse Blanc', '5B', 0xffe0a020),
    ('Rain On The Radio', 'Deniz Okafor', '9A', 0xff8040d0),
  ];
  Genome _genome = Genome.none;
  int _record = -1;
  final _dynamics = ShowDynamics();

  static const _lines = [
    'you came in with the lights',
    'and the room began to turn',
    'this is where we meet',
    'nothing left to learn',
  ];

  /// The sections of the sixty-four-bar form, with the energy of each.
  static const _form = [
    ('intro', 0, 8, 0.25, false),
    ('build', 8, 16, 0.6, false),
    ('drop', 16, 32, 1.0, false),
    ('breakdown', 32, 40, 0.3, true),
    ('build', 40, 48, 0.7, false),
    ('drop', 48, 64, 1.0, false),
  ];

  void start() {
    if (_timer != null) return;
    _began ??= DateTime.now();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) => tick(DateTime.now()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// The frame at [now], or at [elapsed] into the record: for a test.
  void tick(DateTime now, {Duration? elapsed}) {
    final began = _began ??= now;
    final t = (elapsed ?? now.difference(began)).inMicroseconds / 1e6;
    final dt = _last == null ? 0.0 : now.difference(_last!).inMicroseconds / 1e6;
    _last = now;
    final prev = _state;

    final beatLen = 60 / bpm;
    final beatsTotal = t / beatLen;
    final beatIndex = beatsTotal.floor();
    final beatPhase = beatsTotal - beatIndex;
    final barIndex = beatIndex ~/ 4;
    final beatInBar = beatIndex % 4;
    final barPhase = (beatInBar + beatPhase) / 4;
    final formBar = barIndex % 64;
    final sec = _form.firstWhere((s) => formBar >= s.$2 && formBar < s.$3);
    final (label, from, to, energy, sung) = sec;
    final sectionK = ((formBar - from) + barPhase) / (to - from);
    final barsLeft = (to - from) - ((formBar - from) + barPhase);
    // The next drop: the next section called drop, in beats.
    double? dropAway;
    for (final s in _form) {
      if (s.$1 != 'drop') continue;
      final startBeat = (barIndex - formBar + s.$2) * 4;
      final away = startBeat - beatsTotal;
      if (away >= -2 && away <= 64) {
        dropAway = away;
        break;
      }
    }
    if (dropAway == null && label == 'drop') {
      final startBeat = (barIndex - formBar + from) * 4;
      final away = startBeat - beatsTotal;
      if (away >= -2) dropAway = away;
    }
    final buildK = label == 'build' ? sectionK : (dropAway != null && dropAway > 0 && dropAway <= 32 ? 1 - dropAway / 32 : 0.0);

    // The pulse, made up.
    final kick = math.exp(-beatPhase * 9) * (label == 'breakdown' ? 0.0 : 1.0);
    final hat = ((beatPhase * 2) % 1) < 0.15 ? 0.9 : 0.25;
    final audio = ShowAudio(
      sub: (0.3 + 0.7 * kick) * energy,
      low: (0.4 + 0.5 * kick) * energy,
      mid: (0.35 + 0.15 * math.sin(t * 3)) * energy + (sung ? 0.3 : 0),
      high: hat * energy,
      air: hat * 0.7 * energy,
      kick: kick,
      onset: math.max(kick, hat > 0.5 ? 0.6 : 0.0),
      drums: label == 'breakdown' ? 0 : energy,
      rest: energy * 0.8,
      vocals: sung ? 0.8 : 0.05,
    );
    final line = sung ? _lines[(barIndex ~/ 2) % _lines.length] : null;
    final lyricK = sung ? ((barIndex % 2) + barPhase) / 2 : 0.0;

    final hue = (t / 180) % 1;
    // A new record every time the form comes round.
    final record = barIndex ~/ 64;
    if (record != _record) {
      _record = record;
      final r = _records[record % _records.length];
      _genome = Genome.of(trackId: 1 + record % _records.length, camelot: r.$3, bpm: bpm, cover: Color(r.$4));
    }
    final rec = _records[record % _records.length];
    final deck = ShowDeck(
      name: 'A',
      trackId: 1 + record % _records.length,
      title: rec.$1,
      artist: rec.$2,
      playing: true,
      position: Duration(microseconds: (t * 1e6).round()),
      bpm: bpm,
      beatIndex: beatIndex,
      beatPhase: beatPhase,
      beatInBar: beatInBar,
      barIndex: barIndex,
      barPhase: barPhase,
      phraseBar: barIndex % 4,
      phrasePhase: ((barIndex % 4) + barPhase) / 4,
      section: label,
      sectionK: sectionK.clamp(0.0, 1.0),
      sectionBarsLeft: barsLeft,
      dropBeatsAway: dropAway,
      breakdown: label == 'breakdown',
      buildK: buildK.clamp(0.0, 1.0),
      energy: energy,
      vocal: sung ? 0.8 : 0.1,
      lyric: line,
      lyricK: lyricK,
      hook: sung && barIndex % 8 >= 6,
      key: rec.$3,
      camelot: rec.$3,
      keyHue: ((int.tryParse(rec.$3.substring(0, rec.$3.length - 1)) ?? 1) - 1) / 12,
      coverColor: Color(rec.$4),
      coverUrl: 'asset:assets/brand/ball.webp',
      level: 1,
      audio: audio,
    );
    final palette = paletteFor(coverColor: Color(rec.$4), keyHue: hue, section: label, colourTurn: macros.colour + _genome['palette.turn'], apart: _genome.isEmpty ? null : _genome['palette.apart']);
    final hit = macros.hit;
    var st = ShowState(
      now: now,
      dt: dt,
      a: deck,
      b: const ShowDeck(name: 'B'),
      masterName: 'A',
      audio: audio,
      palette: palette,
      macros: macros,
      genome: _genome,
    );
    st = st.copyWith(dyn: {..._dynamics.frame(st, dt), ...CameraFeed.shared.numbers});
    final said = eventsBetween(prev, st);
    final d = director.direct(st, said);
    var m = macros;
    if (director.takeHit() || (said.any((e) => e.kind == ShowEventKind.drop))) {
      m = m.copyWith(hit: 1);
    } else if (hit > 0) {
      m = m.copyWith(hit: (hit - dt / 0.35).clamp(0.0, 1.0));
    }
    macros = m;
    st = st.copyWith(scene: d.scene, sceneFrom: d.from, sceneK: d.k, clearSceneFrom: d.from == null, macros: m);
    _state = st;
    notifyListeners();
    for (final e in said) {
      _events.add(e);
    }
  }

  static ShowState _blank(DateTime now) =>
      ShowState(now: now, a: const ShowDeck(name: 'A'), b: const ShowDeck(name: 'B'));

  @override
  void dispose() {
    stop();
    unawaited(_events.close());
    super.dispose();
  }
}
