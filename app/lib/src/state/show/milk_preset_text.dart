// A MilkDrop preset as text, read and written: for the maker, and for anybody
// who wants to know what a file says without the helper.
//
// The format is Winamp's: `[preset00]`, then `key=value` lines. Numbers set the
// look (zoom, rot, warp, decay, the wave's mode and colour, the borders, the motion
// vectors); `per_frame_N=` lines are code run every frame, `per_pixel_N=` every
// vertex of the warp mesh; `shapecode_I_*` and `wavecode_I_*` set four custom
// shapes and waveforms, with `shape_I_per_frame_N` / `wave_I_per_point_N` code;
// `warp_N=` / `comp_N=` are the two HLSL shaders (MilkDrop 2). Everything not
// understood here is kept as it was, so a forked preset loses nothing.
/// The file, as an ordered map of key to value with the code pulled together.
class MilkText {
  MilkText(this.keys);

  /// Every `key=value` in file order, the code lines included.
  final Map<String, String> keys;

  static MilkText parse(String text) {
    final keys = <String, String>{};
    for (var line in text.split(RegExp(r'\r?\n'))) {
      if (line.trim().isEmpty || line.startsWith('[')) continue;
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      keys[line.substring(0, eq).trim()] = line.substring(eq + 1);
    }
    return MilkText(keys);
  }

  static MilkText blank() => parse(blankPreset);

  double num(String key, [double d = 0]) => double.tryParse(keys[key] ?? '') ?? d;
  int integer(String key, [int d = 0]) => (double.tryParse(keys[key] ?? '') ?? d.toDouble()).round();
  void set(String key, Object value) => keys[key] = value is double ? _fmt(value) : '$value';

  static String _fmt(double v) => v == v.roundToDouble() && v.abs() < 1e6 ? '${v.round()}' : v.toStringAsFixed(6).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');

  /// The numbered lines of one kind of code (`per_frame_`, `per_pixel_`,
  /// `shape_0_per_frame`, `warp_`, …), joined.
  String code(String prefix) {
    final lines = <(int, String)>[];
    for (final e in keys.entries) {
      if (!e.key.startsWith(prefix)) continue;
      final n = int.tryParse(e.key.substring(prefix.length));
      if (n != null) lines.add((n, e.value));
    }
    lines.sort((a, b) => a.$1.compareTo(b.$1));
    return lines.map((l) => l.$2).join('\n');
  }

  /// The code of one kind replaced, line by line.
  void setCode(String prefix, String text) {
    keys.removeWhere((k, _) => k.startsWith(prefix) && int.tryParse(k.substring(prefix.length)) != null);
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    for (var i = 0; i < lines.length; i++) {
      keys['$prefix${i + 1}'] = lines[i];
    }
  }

  /// The prefixes of the code a preset can carry.
  static const codePrefixes = ['per_frame_init_', 'per_frame_', 'per_pixel_', 'warp_', 'comp_'];
  static String shapeInit(int i) => 'shape_${i}_init_';
  static String shapeFrame(int i) => 'shape_${i}_per_frame';
  static String waveInit(int i) => 'wave_${i}_init_';
  static String waveFrame(int i) => 'wave_${i}_per_frame';
  static String wavePoint(int i) => 'wave_${i}_per_point';

  bool get hasShaders => keys.containsKey('warp_1') || keys.containsKey('comp_1');

  @override
  String toString() {
    final b = StringBuffer('[preset00]\n');
    // The numbers first, the code after, the way the files are written.
    final later = <String>[];
    for (final e in keys.entries) {
      if (_isCode(e.key)) {
        later.add('${e.key}=${e.value}');
      } else {
        b.writeln('${e.key}=${e.value}');
      }
    }
    for (final l in later) {
      b.writeln(l);
    }
    return b.toString();
  }

  static bool _isCode(String k) =>
      k.startsWith('per_frame') || k.startsWith('per_pixel') || k.startsWith('warp_') || k.startsWith('comp_') ||
      RegExp(r'^(shape|wave)_\d_(init|per_frame|per_point)').hasMatch(k);

  /// The numbers a preset starts from: MilkDrop's defaults, which every key the
  /// maker shows is read against.
  static const blankPreset = '''[preset00]
fRating=3
fGammaAdj=2
fDecay=0.98
fVideoEchoZoom=1
fVideoEchoAlpha=0
nVideoEchoOrientation=0
nWaveMode=0
bAdditiveWaves=0
bWaveDots=0
bWaveThick=0
bModWaveAlphaByVolume=0
bMaximizeWaveColor=1
bTexWrap=1
bDarkenCenter=0
bRedBlueStereo=0
bBrighten=0
bDarken=0
bSolarize=0
bInvert=0
fWaveAlpha=0.8
fWaveScale=1
fWaveSmoothing=0.75
fWaveParam=0
fModWaveAlphaStart=0.75
fModWaveAlphaEnd=0.95
fWarpAnimSpeed=1
fWarpScale=1
fZoomExponent=1
fShader=0
zoom=1
rot=0
cx=0.5
cy=0.5
dx=0
dy=0
warp=1
sx=1
sy=1
wave_r=0.6
wave_g=0.6
wave_b=0.6
wave_x=0.5
wave_y=0.5
ob_size=0.01
ob_r=0
ob_g=0
ob_b=0
ob_a=0
ib_size=0.01
ib_r=0.25
ib_g=0.25
ib_b=0.25
ib_a=0
nMotionVectorsX=12
nMotionVectorsY=9
mv_dx=0
mv_dy=0
mv_l=0.9
mv_r=1
mv_g=1
mv_b=1
mv_a=0
''';
}

/// One of the four custom shapes, as the maker shows it.
class MilkShape {
  MilkShape(this.text, this.index);
  final MilkText text;
  final int index;
  String _k(String s) => 'shapecode_${index}_$s';

  bool get enabled => text.integer(_k('enabled')) != 0;
  set enabled(bool v) => text.set(_k('enabled'), v ? 1 : 0);
  int get sides => text.integer(_k('sides'), 4);
  set sides(int v) => text.set(_k('sides'), v);
  double get x => text.num(_k('x'), 0.5);
  set x(double v) => text.set(_k('x'), v);
  double get y => text.num(_k('y'), 0.5);
  set y(double v) => text.set(_k('y'), v);
  double get rad => text.num(_k('rad'), 0.1);
  set rad(double v) => text.set(_k('rad'), v);
  double get ang => text.num(_k('ang'), 0);
  set ang(double v) => text.set(_k('ang'), v);
  bool get additive => text.integer(_k('additive')) != 0;
  set additive(bool v) => text.set(_k('additive'), v ? 1 : 0);
  bool get thick => text.integer(_k('thickOutline')) != 0;
  set thick(bool v) => text.set(_k('thickOutline'), v ? 1 : 0);
  bool get textured => text.integer(_k('textured')) != 0;
  set textured(bool v) => text.set(_k('textured'), v ? 1 : 0);
  int get instances => text.integer(_k('num_inst'), 1);
  set instances(int v) => text.set(_k('num_inst'), v);

  /// The colours: the middle (r g b a), the edge (r2 g2 b2 a2), the border.
  List<double> get inner => [text.num(_k('r'), 1), text.num(_k('g'), 0), text.num(_k('b'), 0), text.num(_k('a'), 1)];
  set inner(List<double> c) {
    text.set(_k('r'), c[0]);
    text.set(_k('g'), c[1]);
    text.set(_k('b'), c[2]);
    text.set(_k('a'), c[3]);
  }

  List<double> get outer => [text.num(_k('r2'), 0), text.num(_k('g2'), 1), text.num(_k('b2'), 0), text.num(_k('a2'), 0)];
  set outer(List<double> c) {
    text.set(_k('r2'), c[0]);
    text.set(_k('g2'), c[1]);
    text.set(_k('b2'), c[2]);
    text.set(_k('a2'), c[3]);
  }

  List<double> get border => [text.num(_k('border_r'), 1), text.num(_k('border_g'), 1), text.num(_k('border_b'), 1), text.num(_k('border_a'), 0.1)];
  set border(List<double> c) {
    text.set(_k('border_r'), c[0]);
    text.set(_k('border_g'), c[1]);
    text.set(_k('border_b'), c[2]);
    text.set(_k('border_a'), c[3]);
  }

  String get code => text.code(MilkText.shapeFrame(index));
  set code(String s) => text.setCode(MilkText.shapeFrame(index), s);

  /// Every key a shape needs, where it has none yet.
  void ensure() {
    void d(String k, Object v) => text.keys.putIfAbsent(_k(k), () => '$v');
    d('enabled', 0);
    d('sides', 4);
    d('additive', 0);
    d('thickOutline', 0);
    d('textured', 0);
    d('num_inst', 1);
    d('x', 0.5);
    d('y', 0.5);
    d('rad', 0.1);
    d('ang', 0);
    d('tex_ang', 0);
    d('tex_zoom', 1);
    d('r', 1);
    d('g', 0);
    d('b', 0);
    d('a', 1);
    d('r2', 0);
    d('g2', 1);
    d('b2', 0);
    d('a2', 0);
    d('border_r', 1);
    d('border_g', 1);
    d('border_b', 1);
    d('border_a', 0.1);
  }
}

/// A reaction the maker writes as a line of per-frame code: a target the preset
/// has (zoom, rot, warp, …) pushed by one of the show's numbers.
class MilkReaction {
  const MilkReaction({required this.target, required this.source, required this.amount, this.shape = 'pulse'});
  final String target;

  /// A wo_* name, or MilkDrop's own bass/mid/treb.
  final String source;
  final double amount;

  /// `pulse`: added as it is; `sin`: a swing at the source's phase (for the saws);
  /// `step`: on past a half.
  final String shape;

  String get line => switch (shape) {
        'sin' => '$target = $target + ${_f(amount)}*sin($source*6.2832);',
        'step' => '$target = $target + ${_f(amount)}*above($source,0.5);',
        _ => '$target = $target + ${_f(amount)}*$source;',
      };

  static String _f(double v) => v.toStringAsFixed(3);

  /// The line read back, where it was written here.
  static MilkReaction? parse(String line) {
    final m = RegExp(r'^(\w+) = \1 \+ (-?[\d.]+)\*(?:sin\((\w+)\*6\.2832\)|above\((\w+),0\.5\)|(\w+));$').firstMatch(line.trim());
    if (m == null) return null;
    final amount = double.tryParse(m.group(2)!) ?? 0;
    if (m.group(3) != null) return MilkReaction(target: m.group(1)!, source: m.group(3)!, amount: amount, shape: 'sin');
    if (m.group(4) != null) return MilkReaction(target: m.group(1)!, source: m.group(4)!, amount: amount, shape: 'step');
    return MilkReaction(target: m.group(1)!, source: m.group(5)!, amount: amount);
  }

  /// What a reaction can push, with what each does.
  static const targets = {
    'zoom': 'zoom in (over 1) or out',
    'rot': 'turn, radians a frame',
    'warp': 'the warp\'s strength',
    'decay': 'how much of the last frame stays (1 all)',
    'dx': 'slide across',
    'dy': 'slide down',
    'sx': 'stretch across',
    'sy': 'stretch down',
    'cx': 'the zoom\'s middle, across',
    'cy': 'the zoom\'s middle, down',
    'wave_a': 'the wave\'s brightness',
    'wave_r': 'the wave\'s red',
    'wave_g': 'the wave\'s green',
    'wave_b': 'the wave\'s blue',
    'wave_x': 'the wave\'s place, across',
    'wave_y': 'the wave\'s place, down',
    'wave_mystery': 'the wave mode\'s own knob',
    'ob_size': 'the outer border',
    'ib_size': 'the inner border',
    'echo_zoom': 'the video echo\'s zoom',
    'echo_alpha': 'the video echo\'s strength',
    'gamma': 'brightness',
    'mv_a': 'the motion vectors',
  };

  /// What the show hands a preset, with what each is.
  static const sources = {
    'wo_kick': 'the kick drum, now (0..1)',
    'wo_hit_kick': 'the kick\'s hit: 1 as it lands, gone in 0.2 s',
    'wo_hit_snare': 'the snare\'s hit',
    'wo_hit_top': 'the hats\' hit',
    'wo_beat': '0..1 through the beat (grid)',
    'wo_beat_decay': 'falls from 1 at each beat',
    'wo_bar': '0..1 through the bar',
    'wo_bar_decay': 'falls from 1 at each bar',
    'wo_downbeat': 'the bar decay on beat one only',
    'wo_phrase': '0..1 through the four-bar phrase',
    'wo_low': 'the bass band, through the mixer',
    'wo_mid': 'the middle',
    'wo_high': 'the top',
    'wo_air': 'the air',
    'wo_band_low': 'the bass against the record\'s own loud',
    'wo_band_mid': 'the middle, the same',
    'wo_band_high': 'the top, the same',
    'wo_energy': 'the bar\'s energy',
    'wo_build': 'up a build, 0..1',
    'wo_drop': '1 as a drop lands, 0 thirty-two beats off',
    'wo_breakdown': '1 in a breakdown',
    'wo_hit': 'the hands\' hit, falling',
    'wo_vocal': 'the voice\'s share',
    'wo_hue': 'the palette\'s hue, 0..1 round the wheel',
    'wo_hue2': 'the second hue',
    'wo_exposure': 'how loud it has been, 0.35..1.2',
    'wo_mix': 'how far through a mix',
    'wo_cam_motion': 'how much the room moves',
    'bass': 'MilkDrop\'s own bass (1 = average)',
    'mid': 'MilkDrop\'s middle',
    'treb': 'MilkDrop\'s treble',
    'bass_att': 'the bass, smoothed',
  };
}
