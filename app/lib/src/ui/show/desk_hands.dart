// The Desk's hands on the show beyond the ones any stage takes (desk_show_source.dart
// deskSaid: hit, next, previous, mosh, hold, blackout, strobe, freeze): what the v1
// SHOW page's PERFORM does — the look on judged (NEVER THIS and WIDER, LESS, MORE,
// KEEP, and UNDO), every hold let go, a set put on — and the stage's window put full
// screen on a screen. And back to the Desk with the picture, what it needs to show
// them: the look in words, the holds, the sets, the last thing said, the screens.
//
//   {"t":"hands","do":"never"|"wider"|"less"|"more"|"keep"|"undo"|"letgo"}
//   {"t":"hands","do":"set","id":"<a set's id, or empty for the show as shipped>"}
//   {"t":"hands","do":"screen","name":"<a screen's name>"}   full screen there
//   {"t":"hands","do":"full","on":bool}                       full screen where it is
//
//   {"t":"shown","scene","held","look","holds","blackout","freeze",
//    "sets":[{"id","name"}],"set","said","saidN","undo","wider",
//    "screens":[{"name","w","h"}],"screen","full"}
import 'dart:async';
import 'dart:convert';

import '../../state/show/show_combos.dart';
import '../../state/show/show_engine.dart';
import '../../state/show/show_plan.dart';
import 'show_faves.dart';
import 'show_room.dart' show showComboWords;
import 'stage_kit.dart';
import 'stage_screens.dart';

class DeskHands {
  DeskHands(this.show, this.kit);

  final ShowEngine show;
  final StageKit? kit;

  /// The plan before the last judging, for UNDO.
  ShowPlan? _before;

  /// The last NEVER: its look and how wide it reached, for WIDER.
  Combo? _never;
  int _neverScope = 0;

  /// The last thing the hands were told, counted (a new count is news for the Desk).
  String? said;
  int saidN = 0;

  List<StageScreen> screens = const [];
  String? screen;
  bool full = false;

  void _say(String words) {
    said = words;
    saidN++;
  }

  /// A look in words, its scene by the name the show's looks give it.
  String _words(Combo c) {
    final w = showComboWords(c, kit?.book);
    final name = show.looks[c.scene]?.name;
    return name != null && w.startsWith(c.scene) ? name + w.substring(c.scene.length) : w;
  }

  /// A `hands` line this takes: true when it was one of these.
  bool handle(String line) {
    if (!line.startsWith('{"t":"hands"')) return false;
    final Object? j;
    try {
      j = jsonDecode(line);
    } catch (_) {
      return false;
    }
    if (j is! Map) return false;
    switch (j['do']) {
      case 'never':
        _neverOn(0);
      case 'wider':
        if (_never != null && _neverScope < 2) _neverOn(_neverScope + 1, again: true);
      case 'less':
        _scale(0.5);
      case 'more':
        _scale(2);
      case 'keep':
        unawaited(_keep());
      case 'undo':
        final b = _before;
        if (b != null) {
          show.setPlan(b);
          _before = null;
          _never = null;
          _say('Undone');
        }
      case 'letgo':
        if (show.holds.isNotEmpty) {
          show.letGoAll();
          _say('Let go: the director has it all');
        }
      case 'set':
        _useSet(j['id'] is String ? j['id'] as String : '');
      case 'screen':
        if (j['name'] is String) unawaited(fill(j['name'] as String));
      case 'full':
        unawaited(_full(j['on'] != false));
      default:
        return false;
    }
    return true;
  }

  void _neverOn(int scope, {bool again = false}) {
    final c = again ? _never : show.combo;
    if (c == null) return;
    // WIDER reaches from the plan before the first NEVER, as the v1 message does
    final before = again ? (_before ?? show.pool.plan) : show.pool.plan;
    final scene = show.looks[c.scene]?.name ?? c.scene;
    final s = c.world ? 2 : scope;
    final (plan, words) = switch (s) {
      0 => (before.withCell(c.scene, cellOf(c), 0), 'Never: ${_words(c)}'),
      1 => (before.withCell(c.scene, cellKey(style: c.style, ground: c.ground), 0), 'Never: $scene · ${c.style}, any mask and blend'),
      _ => (before.withIn(c.scene, PlanAxis.style, c.style, muted: true), 'Never: $scene in ${c.style == 'raw' ? 'its own style' : c.style}'),
    };
    _before = before;
    _never = c;
    _neverScope = s;
    show.setPlan(plan);
    _say(words);
  }

  void _scale(double k) {
    final c = show.combo;
    if (c == null || c.world) return;
    final before = show.pool.plan;
    final key = cellOf(c);
    final next = before.scaleCell(c.scene, key, k);
    _before = before;
    _never = null;
    show.setPlan(next);
    _say('${k < 1 ? 'Less' : 'More'}: ${_words(c)} — ${levelWord(next.of(c.scene).cells[key] ?? 1)}');
  }

  Future<void> _keep() async {
    final f = await keepFaveNow(show);
    _say(f == null ? 'Nothing on to keep' : 'Kept: ${show.combo == null ? 'the stage' : _words(show.combo!)}');
  }

  void _useSet(String id) {
    final shelf = show.snapshots;
    if (id.isEmpty) {
      shelf.useShipped();
      _say('The show as shipped');
      return;
    }
    for (final s in shelf.all) {
      if (s.id == id) {
        shelf.use(s);
        _say('Set: ${s.name}');
        return;
      }
    }
  }

  /// Full screen on the screen called [name] (the Desk's choice, kept there).
  Future<void> fill(String name) async {
    screens = await StageScreens.list();
    final i = screens.indexWhere((s) => s.name == name);
    if (i < 0) {
      _say('No screen called $name here');
      return;
    }
    if (await StageScreens.fillScreen(i)) {
      screen = name;
      full = true;
    }
  }

  Future<void> _full(bool on) async {
    await StageScreens.setFull(on);
    full = on;
    if (!on) screen = null;
  }

  /// The screens again (one plugged in or out), and whether the window is full screen.
  Future<void> look() async {
    screens = await StageScreens.list();
    full = await StageScreens.isFull();
    if (!full) screen = null;
  }

  /// What the stage shows, for the Desk's panel.
  String shownJson() {
    final id = show.state.scene;
    final c = show.combo;
    final shelf = show.snapshots;
    final m = show.macros;
    return jsonEncode({
      't': 'shown',
      'scene': id == null ? null : show.looks[id]?.name ?? id,
      'held': show.sceneHeld,
      'look': c == null ? null : _words(c),
      'holds': show.holds.length,
      'blackout': m.blackout,
      'freeze': m.freeze,
      'sets': [
        for (final s in shelf.all) {'id': s.id, 'name': s.name},
      ],
      'set': shelf.on?.id,
      'said': said,
      'saidN': saidN,
      'undo': _before != null,
      'wider': _never != null && _neverScope < 2 && !_never!.world,
      'screens': [
        for (final s in screens) {'name': s.name, 'w': s.width, 'h': s.height},
      ],
      'screen': screen,
      'full': full,
    });
  }
}
