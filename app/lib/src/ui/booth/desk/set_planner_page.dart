import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../api/models.dart';
import '../../../state/app_state.dart';
import '../../../state/booth/automix.dart';
import '../../../state/booth/booth.dart';
import '../../../state/booth/dj_set.dart';
import '../../../state/booth/planner.dart';
import '../../artwork.dart';
import '../../feel.dart';
import '../../mag.dart';
import '../../snack.dart';
import '../../theme.dart';
import 'auto_bits.dart';
import 'console.dart';
import 'console_set.dart' show StyleDials;
import 'data_marks.dart';

/// Into the planner, over the booth.
Future<void> openSetPlanner(BuildContext context, Booth booth) => Navigator.of(context)
    .push(MaterialPageRoute(builder: (_) => SetPlannerPage(booth: booth), fullscreenDialog: true));

/// Where the set is started from.
enum _StartFrom { now, chosen, best }

const _kShape = 'muse.booth.setShape', _kSource = 'muse.booth.setSource';

/// PLAN A SET: where the records come from (the whole library, playlists, the
/// queue), how the set should go (its length, its energy over time, its tempo, how
/// strict about keys, how varied, how familiar), and the set the house builds from
/// that — every record with how well it follows the one before and why, the moves
/// between them, the curve it follows. Everything a hand changes builds it again,
/// around the records pinned; a record can be swapped for another that fits, moved,
/// pinned, taken out (the gap bridged). Then it is played — now, or after the record
/// on — or queued, or kept as a playlist.
class SetPlannerPage extends StatefulWidget {
  const SetPlannerPage({super.key, required this.booth});
  final Booth booth;

  @override
  State<SetPlannerPage> createState() => _SetPlannerPageState();
}

class _SetPlannerPageState extends State<SetPlannerPage> {
  late SetSource _source;
  late SetShape _shape;
  var _startFrom = _StartFrom.now;
  Track? _chosenStart;
  final _must = <Track>[];
  final _excluded = <int>{};
  final _moves = <(int, int), MixPlan>{};

  DjSet? _set;
  PoolStats? _stats;
  bool _building = false;
  bool _judging = false;
  String? _trouble;
  int _ticket = 0;
  Timer? _soon;

  Booth get _b => widget.booth;
  AutoMix get _auto => _b.auto;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    final kept = _auto.set;
    _source = kept?.source ?? const SetSource(library: true);
    _shape = kept?.shape.copyWith(offset: 0, noAnchor: true) ?? const SetShape();
    _set = kept == null ? null : DjSet(source: kept.source, shape: kept.shape, slots: _upcomingOf(kept), curve: kept.curve);
    _startFrom = _b.master.track != null ? _StartFrom.now : _StartFrom.best;
    _auto.addListener(_changed);
    unawaited(_auto.learnTaste());
    if (app.playlists.isEmpty) unawaited(app.refreshPlaylists().catchError((_) {}));
    unawaited(_restore(kept == null));
  }

  /// A set already playing, as the planner shows it: what is still to come.
  List<SetSlot> _upcomingOf(DjSet s) {
    final played = _auto.setPlayedIds.toSet();
    final on = _auto.current?.id;
    return [for (final x in s.slots) if (!played.contains(x.track.id) && x.track.id != on) x];
  }

  /// The shape and pool last used, then a first set to look at.
  Future<void> _restore(bool build) async {
    if (build) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final shape = prefs.getString(_kShape), source = prefs.getString(_kSource);
        if (shape != null) _shape = SetShape.fromKeep((jsonDecode(shape) as Map).cast<String, dynamic>());
        if (source != null) _source = SetSource.fromKeep((jsonDecode(source) as Map).cast<String, dynamic>());
      } catch (_) {}
      if (!mounted) return;
      // A queue named from an earlier session is not necessarily the one open now.
      final q = context.read<AppState>().activeQueue?.id;
      if (_source.queueId != null && _source.queueId != q) {
        _source = q == null ? _source.copyWith(noQueue: true) : _source.copyWith(queueId: q);
      }
      if (_source.isEmpty) _source = const SetSource(library: true);
      setState(() {});
    }
    unawaited(_pool());
    if (build) unawaited(_build());
  }

  Future<void> _keep() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kShape, jsonEncode(_shape.toKeep()));
      await prefs.setString(_kSource, jsonEncode(_source.toKeep()));
    } catch (_) {}
  }

  @override
  void dispose() {
    _soon?.cancel();
    _auto.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------------ asking the house
  Future<void> _pool() async {
    final source = _source;
    if (source.isEmpty) return;
    try {
      final got = await _auto.house.pool(source).timeout(const Duration(seconds: 20));
      if (mounted && source == _source) setState(() => _stats = got);
    } catch (_) {}
  }

  /// Built again in a moment: every dial turned asks, the last one is answered.
  void _rebuildSoon({bool pool = false}) {
    _soon?.cancel();
    _soon = Timer(const Duration(milliseconds: 450), () {
      if (pool) unawaited(_pool());
      unawaited(_build());
    });
  }

  Track? get _start => switch (_startFrom) {
        _StartFrom.now => _b.master.track,
        _StartFrom.chosen => _chosenStart,
        _StartFrom.best => null,
      };

  /// The set from the house: from the pool, to the shape, around what is pinned —
  /// then judged again here, record by record.
  Future<void> _build({List<({int id, int slot})>? pins, Set<int>? pinnedAfter}) async {
    if (_source.isEmpty) {
      setState(() => _trouble = 'Choose where the records come from.');
      return;
    }
    final ticket = ++_ticket;
    final set = _set;
    final start = _start;
    final pinned = pins ??
        [
          if (set != null)
            for (final (i, s) in set.slots.indexed)
              if (s.pinned && !_must.any((m) => m.id == s.track.id)) (id: s.track.id, slot: i),
        ];
    setState(() {
      _building = true;
      _trouble = null;
    });
    unawaited(_keep());
    try {
      final built = await _auto.house
          .build(
            source: _source,
            shape: _shape,
            start: start,
            before: start == null ? const [] : _auto.tracks.take(math.max(0, _auto.at)).toList().reversed.take(4).toList(),
            pins: pinned,
            must: [for (final t in _must) t.id],
            exclude: {..._excluded, if (start != null) start.id},
            pitch: start != null && identical(start, _auto.current) ? _auto.masterTargetPitch : 1,
          )
          .timeout(const Duration(seconds: 30));
      if (!mounted || ticket != _ticket) return;
      // Records held in place only to build around them are not pinned by a hand.
      final shown = pinnedAfter == null
          ? built
          : built.copyWith(slots: [
              for (final x in built.slots)
                x.copyWith(pinned: pinnedAfter.contains(x.track.id) || _must.any((m) => m.id == x.track.id)),
            ]);
      setState(() {
        _set = shown;
        _stats = built.stats ?? _stats;
        _building = false;
        _judging = true;
      });
      final judged = await _auto.judgeSet(shown, from: start);
      if (!mounted || ticket != _ticket) return;
      setState(() {
        _set = judged;
        _judging = false;
      });
    } catch (e) {
      if (!mounted || ticket != _ticket) return;
      setState(() {
        _building = false;
        _judging = false;
        final said = '$e'.split('\n').first;
        _trouble = e is TimeoutException
            ? 'The house took too long to answer.'
            : 'The house could not build it: ${said.length > 140 ? '${said.substring(0, 140)}…' : said}';
      });
    }
  }

  void _shapeTo(SetShape s) {
    setState(() => _shape = s);
    _rebuildSoon();
  }

  void _sourceTo(SetSource s) {
    setState(() {
      _source = s;
      _stats = null;
    });
    _rebuildSoon(pool: true);
  }

  // ------------------------------------------------------------------ a hand on the set
  void _slots(List<SetSlot> slots) {
    final s = _set;
    if (s == null) return;
    setState(() => _set = s.copyWith(slots: slots).retimed());
  }

  void _togglePin(int i) {
    final s = _set;
    if (s == null) return;
    final slots = [...s.slots];
    slots[i] = slots[i].copyWith(pinned: !slots[i].pinned);
    _slots(slots);
  }

  void _moveRow(int from, int to) {
    final s = _set;
    if (s == null) return;
    final slots = [...s.slots];
    final x = slots.removeAt(from);
    // Put where a hand put it: pinned there.
    slots.insert(to > from ? to - 1 : to, x.copyWith(pinned: true));
    _slots(slots);
    unawaited(_rejudge());
  }

  Future<void> _rejudge() async {
    final s = _set;
    if (s == null) return;
    final ticket = ++_ticket;
    setState(() => _judging = true);
    final judged = await _auto.judgeSet(s, from: _start);
    if (!mounted || ticket != _ticket) return;
    setState(() {
      _set = judged;
      _judging = false;
    });
  }

  /// Taken out, and never offered again: everything else stays where it is and the
  /// gap is bridged by the record that fits both sides best.
  void _remove(int i) {
    final s = _set;
    if (s == null) return;
    final gone = s.slots[i].track;
    _excluded.add(gone.id);
    _must.removeWhere((t) => t.id == gone.id);
    final keep = [
      for (final (j, x) in s.slots.indexed)
        if (j != i) (id: x.track.id, slot: j < i ? j : j - 1),
    ];
    // One free slot where it was: the bridge.
    final pins = [for (final p in keep) (id: p.id, slot: p.slot >= i ? p.slot + 1 : p.slot)];
    final pinned = {for (final x in s.slots) if (x.pinned) x.track.id};
    _slots([for (final (j, x) in s.slots.indexed) if (j != i) x]);
    unawaited(_build(pins: pins, pinnedAfter: pinned));
  }

  void _mustPlay(Track t) {
    if (_must.any((x) => x.id == t.id)) return;
    setState(() => _must.add(t));
    _rebuildSoon();
  }

  void _startWith(Track t) {
    setState(() {
      _startFrom = _StartFrom.chosen;
      _chosenStart = t;
      _excluded.remove(t.id);
    });
    _rebuildSoon();
  }

  Future<void> _instead(int i) async {
    final s = _set;
    if (s == null) return;
    final prev = i == 0 ? _start : s.slots[i - 1].track;
    final next = i + 1 < s.slots.length ? s.slots[i + 1].track : null;
    final picked = await showDialog<SlotChoice>(
      context: context,
      builder: (context) => _InsteadDialog(
        future: _auto.house.choices(
          source: _source,
          shape: _shape,
          prev: prev,
          next: next,
          k: s.slots.length <= 1 ? 0 : i / (s.slots.length - 1),
          exclude: [for (final x in s.slots) x.track.id, ..._excluded, if (prev != null) prev.id],
          limit: 8,
        ),
        of: s.slots[i].track,
      ),
    );
    if (picked == null || !mounted) return;
    final slots = [...s.slots];
    slots[i] = picked.asSlot.copyWith(pinned: true);
    _slots(slots);
    unawaited(_rejudge());
  }

  // ------------------------------------------------------------------ what becomes of it
  DjSet? get _ready {
    final s = _set;
    if (s == null || s.slots.isEmpty) return null;
    return s;
  }

  Future<void> _play({required bool now}) async {
    final s = _ready;
    if (s == null) return;
    feel(Feel.commit);
    _auto.steers.addAll(_moves);
    unawaited(_keep());
    Navigator.of(context).pop();
    await _auto.playSet(s, now: now);
  }

  Future<void> _queueIt() async {
    final s = _ready;
    if (s == null) return;
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    feel(Feel.pick);
    try {
      await app.addTracks(s.tracks);
      messenger.say(snack(Text('${s.slots.length} records added to the queue')));
    } catch (e) {
      messenger.say(problem(e));
    }
  }

  Future<void> _saveIt() async {
    final s = _ready;
    if (s == null) return;
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final now = DateTime.now();
    final name = 'Set · ${_shape.preset.label} · '
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    try {
      final p = await _b.api.createPlaylist(name);
      await _b.api.addToPlaylist(p.id, [for (final t in s.tracks) t.id]);
      unawaited(app.refreshPlaylists().catchError((_) {}));
      messenger.say(snack(Text('Kept as “$name”')));
    } catch (e) {
      messenger.say(problem(e));
    }
  }

  Future<void> _fetchUnfetched() async {
    final ids = _stats?.unfetchedIds ?? const <int>[];
    if (ids.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await _b.api.fetchAudio(trackIds: ids);
      messenger.say(snack(Text('Fetching ${r.queued} records (about ${r.aboutMb} MB) — they join the pool once measured')));
    } catch (e) {
      messenger.say(problem(e));
    }
  }

  // ------------------------------------------------------------------ the page
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final width = MediaQuery.sizeOf(context).width;
    final accent = Theme.of(context).colorScheme.primary;
    final set = _set;
    final top = Row(
      children: [
        IconButton(
          icon: Icon(Icons.arrow_back, color: Console.quiet),
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(width: 6),
        Text('PLAN A SET', style: Console.label(11, color: Console.ink)),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            [
              if (set != null) '${set.slots.length} RECORDS · ${_clock(set.length)}',
              if (set?.meanFit != null) 'FIT ${set!.meanFit!.toStringAsFixed(2)}',
              if (_building) 'BUILDING…' else if (_judging) 'JUDGING THE MOVES…',
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Console.label(8.5, color: _building ? accent : null),
          ),
        ),
        if (width >= 700) ..._actions(accent),
      ],
    );
    final Widget body;
    if (width >= 1100) {
      body = Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(width: 300, child: Plate(padding: const EdgeInsets.all(12), child: _sourcePanel(app))),
        const SizedBox(width: 12),
        SizedBox(width: 330, child: Plate(padding: const EdgeInsets.all(12), child: _shapePanel())),
        const SizedBox(width: 12),
        Expanded(child: Plate(padding: const EdgeInsets.all(10), child: _setPanel(accent))),
      ]);
    } else if (width >= 700) {
      body = Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 320,
          child: Plate(
            padding: const EdgeInsets.all(12),
            child: ListView(children: [
              _sourcePanel(app, scrolls: false),
              const SizedBox(height: 18),
              _shapePanel(scrolls: false),
            ]),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Plate(padding: const EdgeInsets.all(10), child: _setPanel(accent))),
      ]);
    } else {
      body = DefaultTabController(
        length: 3,
        initialIndex: 2,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TabBar(
            labelStyle: Console.label(9, color: Console.ink),
            unselectedLabelStyle: Console.label(9),
            indicatorColor: accent,
            dividerColor: Console.line,
            tabs: const [Tab(text: 'FROM', height: 34), Tab(text: 'SHAPE', height: 34), Tab(text: 'SET', height: 34)],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TabBarView(children: [
              Plate(padding: const EdgeInsets.all(12), child: _sourcePanel(app)),
              Plate(padding: const EdgeInsets.all(12), child: _shapePanel()),
              Plate(padding: const EdgeInsets.all(8), child: _setPanel(accent)),
            ]),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: _actions(accent))),
        ]),
      );
    }
    return Theme(
      data: Console.light ? MuseTheme.light(app.palette) : MuseTheme.dark(app.palette),
      child: Scaffold(
        backgroundColor: Console.ground,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [top, const SizedBox(height: 10), Expanded(child: body)],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _actions(Color accent) {
    final ok = _ready != null && !_building;
    final running = _auto.running;
    return [
      Pad(
        icon: Icons.bookmark_add_outlined,
        height: 30,
        width: 36,
        tooltip: 'Keep it as a playlist',
        onTap: ok ? () => unawaited(_saveIt()) : null,
      ),
      const SizedBox(width: 4),
      Pad(
        icon: Icons.playlist_add,
        label: 'QUEUE IT',
        height: 30,
        tooltip: 'Add it to the end of the queue, and nothing else',
        onTap: ok ? () => unawaited(_queueIt()) : null,
      ),
      const SizedBox(width: 4),
      if (running) ...[
        Pad(
          icon: Icons.queue_play_next,
          label: MediaQuery.sizeOf(context).width < 700 ? 'AFTER THIS' : 'AFTER THIS ONE',
          height: 30,
          colour: accent,
          tooltip: 'Play it when the record on now ends',
          onTap: ok ? () => unawaited(_play(now: false)) : null,
        ),
        const SizedBox(width: 4),
      ],
      Pad(
        icon: Icons.play_arrow,
        label: running ? 'NOW' : 'PLAY IT',
        height: 30,
        colour: accent,
        lit: true,
        tooltip: running ? 'Into its first record now' : 'Start the Auto DJ on it',
        onTap: ok ? () => unawaited(_play(now: running)) : null,
      ),
    ];
  }

  // ------------------------------------------------------------------ from
  Widget _sourcePanel(AppState app, {bool scrolls = true}) {
    final accent = Theme.of(context).colorScheme.primary;
    final queued = [for (final t in app.player?.items ?? const <Track>[]) if (t.isReady) t];
    final q = app.activeQueue;
    final lists = app.playlists;
    final stats = _stats;
    final chosen = {for (final p in _source.playlists) p.id};
    final head = [
      Text('FROM', style: Console.label(10, color: Console.ink)),
      const SizedBox(height: 8),
      Wrap(spacing: 4, runSpacing: 4, children: [
        Pad(
          icon: Icons.library_music_outlined,
          label: 'THE WHOLE LIBRARY',
          height: 28,
          lit: _source.library,
          colour: accent,
          tooltip: 'Every record in your library the house has measured',
          onTap: () => _sourceTo(_source.copyWith(library: !_source.library)),
        ),
        Pad(
          icon: Icons.queue_music,
          label: 'THE QUEUE · ${queued.length}',
          height: 28,
          lit: _source.queueId != null,
          colour: accent,
          tooltip: 'What is queued now',
          onTap: q == null
              ? null
              : () => _sourceTo(_source.queueId != null ? _source.copyWith(noQueue: true) : _source.copyWith(queueId: q.id)),
        ),
      ]),
      const SizedBox(height: 8),
      _PoolLine(stats: stats, onFetch: _fetchUnfetched),
      const SizedBox(height: 12),
      Text('PLAYLISTS${chosen.isEmpty ? '' : ' · ${chosen.length} CHOSEN'}', style: Console.label(8.5)),
      const SizedBox(height: 4),
    ];
    final playlistRows = [
      for (final p in lists)
        InkWell(
          onTap: () {
            final next = chosen.contains(p.id)
                ? [for (final x in _source.playlists) if (x.id != p.id) x]
                : [..._source.playlists, (id: p.id, name: p.name)];
            _sourceTo(_source.copyWith(playlists: next));
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Icon(chosen.contains(p.id) ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 16, color: chosen.contains(p.id) ? accent : Console.faint),
              const SizedBox(width: 8),
              Expanded(child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(11.5, color: Console.ink))),
              Text('${p.itemCount}', style: Mag.typewriter(10, color: Console.faint)),
            ]),
          ),
        ),
      if (lists.isEmpty) Text('No playlists.', style: Mag.typewriter(10.5, color: Console.faint)),
    ];
    final tail = [
      const SizedBox(height: 14),
      Text('START FROM', style: Console.label(8.5)),
      const SizedBox(height: 4),
      Wrap(spacing: 4, runSpacing: 4, children: [
        Pad(
          label: 'THE RECORD ON',
          height: 26,
          lit: _startFrom == _StartFrom.now,
          colour: accent,
          tooltip: _b.master.track == null ? 'Nothing is on' : 'Follow ${_b.master.track!.displayTitle}',
          onTap: _b.master.track == null
              ? null
              : () {
                  setState(() => _startFrom = _StartFrom.now);
                  _rebuildSoon();
                },
        ),
        Pad(
          label: 'LET IT CHOOSE',
          height: 26,
          lit: _startFrom == _StartFrom.best,
          colour: accent,
          tooltip: 'The opener that fits the start of the curve best',
          onTap: () {
            setState(() => _startFrom = _StartFrom.best);
            _rebuildSoon();
          },
        ),
        if (_chosenStart != null)
          Pad(
            label: _chosenStart!.displayTitle.toUpperCase(),
            height: 26,
            lit: _startFrom == _StartFrom.chosen,
            colour: accent,
            onTap: () {
              setState(() => _startFrom = _StartFrom.chosen);
              _rebuildSoon();
            },
          ),
      ]),
      const SizedBox(height: 14),
      Row(children: [
        Text('MUST PLAY', style: Console.label(8.5)),
        const Spacer(),
        if (queued.isNotEmpty)
          PopupMenuButton<Track>(
            tooltip: 'A record from the queue',
            color: Console.raised,
            icon: Icon(Icons.add, size: 16, color: Console.quiet),
            onSelected: _mustPlay,
            itemBuilder: (context) => [
              for (final t in queued.take(40))
                PopupMenuItem(value: t, child: Text(t.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(11.5, color: Console.ink))),
            ],
          ),
      ]),
      if (_must.isEmpty)
        Text('None yet: choose it in a record\'s menu in the set, or + for one from the queue.',
            style: Mag.typewriter(10, color: Console.faint))
      else
        Wrap(spacing: 4, runSpacing: 4, children: [
          for (final t in _must)
            InputChip(
              label: Text(t.displayTitle, style: Mag.typewriter(10.5, color: Console.ink)),
              backgroundColor: Console.raised,
              side: BorderSide(color: Console.line),
              onDeleted: () {
                setState(() => _must.removeWhere((x) => x.id == t.id));
                _rebuildSoon();
              },
            ),
        ]),
      if (_excluded.isNotEmpty) ...[
        const SizedBox(height: 10),
        InkWell(
          onTap: () {
            setState(_excluded.clear);
            _rebuildSoon();
          },
          child: Text('${_excluded.length} taken out · let them back', style: Mag.typewriter(10, color: Console.quiet)),
        ),
      ],
    ];
    if (!scrolls) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...head, ...playlistRows, ...tail]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ...head,
      Expanded(child: ListView(children: playlistRows)),
      ...tail,
    ]);
  }

  // ------------------------------------------------------------------ shape
  Widget _shapePanel({bool scrolls = true}) {
    final accent = Theme.of(context).colorScheme.primary;
    final s = _shape;
    final span = _stats?.tempoSpan ?? (100.0, 150.0);
    Widget slider(String low, String high, double v, void Function(double) on, {int? divisions}) => Row(children: [
          SizedBox(width: 66, child: Text(low, style: Console.label(7.5))),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                  trackHeight: 2, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), overlayShape: SliderComponentShape.noOverlay),
              child: Slider(value: v, divisions: divisions, onChanged: on, activeColor: accent, inactiveColor: Console.line),
            ),
          ),
          SizedBox(width: 66, child: Text(high, textAlign: TextAlign.right, style: Console.label(7.5))),
        ]);
    final children = <Widget>[
      Text('SHAPE', style: Console.label(10, color: Console.ink)),
      const SizedBox(height: 10),
      Row(children: [
        Text('LENGTH', style: Console.label(8.5)),
        const SizedBox(width: 8),
        Pad(label: 'RECORDS', height: 24, lit: s.minutes == null, colour: accent, onTap: () => _shapeTo(s.copyWith(byTracks: true))),
        const SizedBox(width: 3),
        Pad(label: 'MINUTES', height: 24, lit: s.minutes != null, colour: accent, onTap: () => _shapeTo(s.copyWith(minutes: s.minutes ?? 60))),
        const Spacer(),
        Text(s.minutes != null ? _clock(Duration(minutes: s.minutes!.round())) : '${s.tracks}', style: Mag.numerals(16, color: Console.ink)),
      ]),
      s.minutes != null
          ? slider('15 MIN', '4 H', ((s.minutes! - 15) / 225).clamp(0.0, 1.0),
              (v) => _shapeTo(s.copyWith(minutes: ((15 + v * 225) / 5).round() * 5.0)),
              divisions: 45)
          : slider('4', '60', ((s.tracks - 4) / 56).clamp(0.0, 1.0), (v) => _shapeTo(s.copyWith(tracks: (4 + v * 56).round())), divisions: 56),
      const SizedBox(height: 12),
      Text('ENERGY OVER THE SET', style: Console.label(8.5)),
      const SizedBox(height: 6),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: CurvePads(selected: s.preset == EnergyPreset.custom ? null : s.preset, onPick: (p) => _shapeTo(s.copyWith(preset: p)), height: 28),
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: 96,
        child: _CurveEditor(
          points: s.points,
          accent: accent,
          onChanged: (pts) => _shapeTo(s.copyWith(preset: EnergyPreset.custom, drawn: pts)),
        ),
      ),
      Text('Drag the points to draw your own. Read against the pool: its softest records to its loudest.',
          style: Mag.typewriter(9.5, color: Console.faint)),
      const SizedBox(height: 12),
      Row(children: [
        Text('TEMPO', style: Console.label(8.5)),
        const SizedBox(width: 8),
        Pad(label: 'ANY', height: 24, lit: s.tempo == null, colour: accent, onTap: () => _shapeTo(s.copyWith(noTempo: true))),
        const SizedBox(width: 3),
        Pad(
          label: 'A PATH',
          height: 24,
          lit: s.tempo != null,
          colour: accent,
          onTap: () => _shapeTo(s.copyWith(tempo: s.tempo ?? (span.$1 + (span.$2 - span.$1) * 0.3, span.$1 + (span.$2 - span.$1) * 0.6))),
        ),
        if (s.tempo != null) ...[
          const SizedBox(width: 3),
          Pad(
            icon: s.tempo!.$2 >= s.tempo!.$1 ? Icons.trending_up : Icons.trending_down,
            height: 24,
            width: 30,
            tooltip: 'Rising or falling',
            onTap: () => _shapeTo(s.copyWith(tempo: (s.tempo!.$2, s.tempo!.$1))),
          ),
          const Spacer(),
          Text('${s.tempo!.$1.round()} → ${s.tempo!.$2.round()}', style: Mag.numerals(15, color: Console.ink)),
        ],
      ]),
      if (s.tempo != null) ...[
        const SizedBox(height: 4),
        SizedBox(height: 26, child: _Histogram(stats: _stats, lo: math.min(s.tempo!.$1, s.tempo!.$2), hi: math.max(s.tempo!.$1, s.tempo!.$2), span: span)),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(trackHeight: 2, overlayShape: SliderComponentShape.noOverlay),
          child: RangeSlider(
            min: span.$1,
            max: math.max(span.$2, span.$1 + 1),
            values: RangeValues(
              math.min(s.tempo!.$1, s.tempo!.$2).clamp(span.$1, span.$2),
              math.max(s.tempo!.$1, s.tempo!.$2).clamp(span.$1, span.$2),
            ),
            activeColor: accent,
            inactiveColor: Console.line,
            onChanged: (r) {
              final rising = s.tempo!.$2 >= s.tempo!.$1;
              _shapeTo(s.copyWith(tempo: rising ? (r.start, r.end) : (r.end, r.start)));
            },
          ),
        ),
      ],
      const SizedBox(height: 12),
      Row(children: [
        Text('KEYS', style: Console.label(8.5)),
        const SizedBox(width: 8),
        for (final k in const ['strict', 'loose', 'any']) ...[
          Pad(
            label: k.toUpperCase(),
            height: 24,
            lit: s.key == k,
            colour: accent,
            tooltip: switch (k) {
              'strict' => 'Never two keys that clash',
              'loose' => 'A clash costs, but may happen',
              _ => 'Keys do not matter',
            },
            onTap: () => _shapeTo(s.copyWith(key: k)),
          ),
          const SizedBox(width: 3),
        ],
      ]),
      const SizedBox(height: 10),
      Text('NO ARTIST AGAIN WITHIN ${s.gap} RECORD${s.gap == 1 ? '' : 'S'}', style: Console.label(8)),
      slider('0', '8', s.gap / 8, (v) => _shapeTo(s.copyWith(gap: (v * 8).round())), divisions: 8),
      const SizedBox(height: 6),
      Text('FROM ONE RECORD TO THE NEXT', style: Console.label(8)),
      slider('CONTRAST', 'ALIKE', s.smooth, (v) => _shapeTo(s.copyWith(smooth: v))),
      const SizedBox(height: 6),
      Text('WHAT TO PICK', style: Console.label(8)),
      slider('FAMILIAR', 'FRESH', s.fresh, (v) => _shapeTo(s.copyWith(fresh: v))),
      const SizedBox(height: 8),
      Row(children: [
        Pad(
          icon: Icons.call_split,
          label: 'RECORDS IN PARTS FIRST',
          height: 26,
          lit: s.stems,
          colour: accent,
          tooltip: 'Prefer records already taken apart: the moves that need stems',
          onTap: () => _shapeTo(s.copyWith(stems: !s.stems)),
        ),
      ]),
      const SizedBox(height: 16),
      StyleDials(auto: _auto),
    ];
    return scrolls
        ? ListView(children: children)
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  // ------------------------------------------------------------------ the set
  Widget _setPanel(Color accent) {
    final set = _set;
    if (set == null || set.slots.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_building) const CircularProgressIndicator(strokeWidth: 2),
          if (_building) const SizedBox(height: 12),
          Text(
            _trouble ??
                (_building
                    ? 'Building a set from ${_source.label.toLowerCase()}…'
                    : set == null
                        ? 'Choose where from and how, and a set is built.'
                        : 'Nothing in ${_source.label.toLowerCase()} fits that shape.'),
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: Mag.typewriter(12, color: _trouble == null ? Console.quiet : Console.a),
          ),
          if (!_building) ...[
            const SizedBox(height: 10),
            Pad(label: 'BUILD IT', icon: Icons.auto_awesome, height: 30, colour: accent, onTap: () => unawaited(_build())),
          ],
        ]),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Text('THE SET', style: Console.label(9, color: accent)),
        const SizedBox(width: 10),
        Expanded(
          child: Text('from ${_source.label.toLowerCase()} · ${_shape.preset.label}'
              '${_shape.tempo == null ? '' : ' · ${_shape.tempo!.$1.round()}→${_shape.tempo!.$2.round()} bpm'}',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(10.5, color: Console.quiet)),
        ),
        if (_trouble != null)
          Flexible(child: Text(_trouble!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(10, color: Console.a))),
        const SizedBox(width: 8),
        Pad(
          icon: Icons.refresh,
          label: 'BUILD AGAIN',
          height: 26,
          colour: Console.ink,
          tooltip: 'Build it again around what is pinned',
          onTap: _building ? null : () => unawaited(_build()),
        ),
      ]),
      const SizedBox(height: 8),
      SizedBox(height: 70, child: _SetChart(set: set, accent: accent)),
      const SizedBox(height: 6),
      Expanded(child: _list(set, accent)),
    ]);
  }

  Widget _list(DjSet set, Color accent) {
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final start = _start;
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      itemCount: set.slots.length,
      proxyDecorator: (child, i, a) => Material(color: Colors.transparent, child: child),
      onReorderItem: _moveRow,
      itemBuilder: (context, i) {
        final slot = set.slots[i];
        final t = slot.track;
        final timing = _b.timing.peek(t.id);
        final prev = i > 0 ? set.slots[i - 1].track : start;
        return Column(
          key: ValueKey('slot-${t.id}'),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (prev != null)
              _MoveRow(
                booth: _b,
                from: prev,
                to: t,
                fit: slot.fit,
                why: slot.why,
                chosen: _moves[(prev.id, t.id)],
                onPick: (p) => setState(() {
                  if (p == null) {
                    _moves.remove((prev.id, t.id));
                  } else {
                    _moves[(prev.id, t.id)] = p;
                  }
                }),
              ),
            Row(
              children: [
                ReorderableDragStartListener(
                  index: i,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(Icons.drag_indicator, size: 16, color: Console.faint),
                  ),
                ),
                if (!narrow) SizedBox(width: 38, child: Text(_mmss(slot.at), style: Mag.typewriter(10, color: Console.faint))),
                Artwork(track: t, size: narrow ? 26 : 30, radius: 3),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.title(13.5, color: Console.ink)),
                      Text(t.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(10, color: Console.quiet)),
                    ],
                  ),
                ),
                if (!narrow) ...[
                  DataMarks(booth: _b, track: t, timing: timing),
                  const SizedBox(width: 8),
                ],
                SizedBox(
                  width: 34,
                  child: Text(slot.camelot ?? timing?.camelot ?? '', textAlign: TextAlign.center, style: Mag.typewriter(10.5, color: Console.quiet, bold: true)),
                ),
                SizedBox(
                  width: 36,
                  child: Text((slot.bpm ?? timing?.gridBpm)?.toStringAsFixed(0) ?? '',
                      textAlign: TextAlign.right, style: Mag.numerals(13.5, color: Console.quiet)),
                ),
                const SizedBox(width: 8),
                _EnergyBar(energy: slot.energy, target: slot.target, accent: accent, width: narrow ? 28 : 54),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(slot.pinned ? Icons.push_pin : Icons.push_pin_outlined, size: 15, color: slot.pinned ? accent : Console.faint),
                  tooltip: slot.pinned ? 'Unpin: the next build may move it' : 'Pin it here',
                  onPressed: () => _togglePin(i),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  color: Console.raised,
                  icon: Icon(Icons.more_horiz, size: 16, color: Console.quiet),
                  onSelected: (v) => switch (v) {
                    'instead' => unawaited(_instead(i)),
                    'remove' => _remove(i),
                    'must' => _mustPlay(t),
                    'start' => _startWith(t),
                    _ => null,
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(value: 'instead', child: Text('Something else here…', style: Mag.typewriter(12, color: Console.ink))),
                    PopupMenuItem(value: 'remove', child: Text('Take it out (the gap bridged)', style: Mag.typewriter(12, color: Console.ink))),
                    if (!_must.any((m) => m.id == t.id))
                      PopupMenuItem(value: 'must', child: Text('Must play — keep it in', style: Mag.typewriter(12, color: Console.ink))),
                    PopupMenuItem(value: 'start', child: Text('Open the set with it', style: Mag.typewriter(12, color: Console.ink))),
                  ],
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  static String _clock(Duration d) {
    final m = d.inMinutes;
    return m >= 60 ? '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m' : '$m min';
  }

  static String _mmss(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}

/// What the pool holds, in a line: measured, not measured yet, never fetched.
class _PoolLine extends StatelessWidget {
  const _PoolLine({required this.stats, required this.onFetch});
  final PoolStats? stats;
  final VoidCallback onFetch;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    if (s == null) return Text('Reading the pool…', style: Mag.typewriter(10, color: Console.faint));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        [
          '${_n(s.measured)} records to choose from',
          if (s.inParts > 0) '${_n(s.inParts)} in parts',
          if (s.unmeasured > 0) '${_n(s.unmeasured)} not measured yet',
        ].join(' · '),
        style: Mag.typewriter(10, color: Console.quiet),
      ),
      if (s.unfetched > 0)
        Row(children: [
          Expanded(
            child: Text('${_n(s.unfetched)} never fetched — not in the pool until they are',
                style: Mag.typewriter(10, color: Console.faint)),
          ),
          if (s.unfetchedIds.isNotEmpty) Pad(label: 'FETCH', icon: Icons.download, height: 22, onTap: onFetch),
        ]),
    ]);
  }

  static String _n(int n) => n >= 1000 ? '${n ~/ 1000},${(n % 1000).toString().padLeft(3, '0')}' : '$n';
}

/// The curve, drawn to be dragged: its points moved up and down (and, between their
/// neighbours, along).
class _CurveEditor extends StatefulWidget {
  const _CurveEditor({required this.points, required this.accent, required this.onChanged});
  final List<(double, double)> points;
  final Color accent;
  final void Function(List<(double, double)>) onChanged;

  @override
  State<_CurveEditor> createState() => _CurveEditorState();
}

class _CurveEditorState extends State<_CurveEditor> {
  List<(double, double)>? _dragging;
  int? _held;

  /// Five points, whatever the curve had: evenly along it, so a preset becomes
  /// something to drag.
  static List<(double, double)> _five(List<(double, double)> pts) {
    double at(double k) {
      for (var i = 0; i + 1 < pts.length; i++) {
        final (k0, e0) = pts[i];
        final (k1, e1) = pts[i + 1];
        if (k >= k0 && k <= k1) return k1 == k0 ? e1 : e0 + (e1 - e0) * (k - k0) / (k1 - k0);
      }
      return pts.last.$2;
    }

    return [for (final k in const [0.0, 0.25, 0.5, 0.75, 1.0]) (k, at(k))];
  }

  @override
  Widget build(BuildContext context) {
    final pts = _dragging ?? widget.points;
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      Offset at((double, double) p) => Offset(p.$1 * size.width, (1 - p.$2) * size.height);
      return GestureDetector(
        onPanStart: (d) {
          final five = pts.length == 5 ? [...pts] : _five(pts);
          var best = 0;
          for (var i = 1; i < five.length; i++) {
            if ((at(five[i]) - d.localPosition).distance < (at(five[best]) - d.localPosition).distance) best = i;
          }
          setState(() {
            _dragging = five;
            _held = best;
          });
        },
        onPanUpdate: (d) {
          final five = _dragging, i = _held;
          if (five == null || i == null) return;
          final e = (1 - d.localPosition.dy / size.height).clamp(0.0, 1.0);
          var k = (d.localPosition.dx / size.width).clamp(0.0, 1.0);
          if (i == 0) k = 0;
          if (i == five.length - 1) k = 1;
          if (i > 0 && i < five.length - 1) k = k.clamp(five[i - 1].$1 + 0.04, five[i + 1].$1 - 0.04);
          setState(() => five[i] = (k, e));
        },
        onPanEnd: (_) {
          final five = _dragging;
          setState(() {
            _dragging = null;
            _held = null;
          });
          if (five != null) widget.onChanged(five);
        },
        child: CustomPaint(
          size: size,
          painter: _CurveEditorPainter(points: pts, accent: widget.accent, held: _held),
        ),
      );
    });
  }
}

class _CurveEditorPainter extends CustomPainter {
  _CurveEditorPainter({required this.points, required this.accent, this.held});
  final List<(double, double)> points;
  final Color accent;
  final int? held;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6));
    canvas.drawRRect(r, Paint()..color = Console.raised);
    for (final y in const [0.25, 0.5, 0.75]) {
      canvas.drawLine(Offset(0, size.height * y), Offset(size.width, size.height * y), Paint()..color = Console.line);
    }
    Offset at((double, double) p) => Offset(p.$1 * size.width, (1 - p.$2) * size.height);
    final fill = Path()..moveTo(0, size.height);
    for (final p in points) {
      final o = at(p);
      fill.lineTo(o.dx, o.dy);
    }
    fill
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = accent.withValues(alpha: 0.12));
    CurvePainter(points, accent, width: 2).paint(canvas, size);
    for (final (i, p) in points.indexed) {
      canvas.drawCircle(at(p), i == held ? 6 : 4, Paint()..color = accent);
    }
    final tp = TextPainter(
      text: TextSpan(text: 'LOUDEST', style: Console.label(6.5, color: Console.faint)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(4, 3));
  }

  @override
  bool shouldRepaint(_CurveEditorPainter old) => true;
}

/// The pool's records by tempo, the chosen range lit.
class _Histogram extends StatelessWidget {
  const _Histogram({required this.stats, required this.lo, required this.hi, required this.span});
  final PoolStats? stats;
  final double lo, hi;
  final (double, double) span;

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _HistogramPainter(stats: stats, lo: lo, hi: hi, span: span, accent: Theme.of(context).colorScheme.primary),
      );
}

class _HistogramPainter extends CustomPainter {
  _HistogramPainter({required this.stats, required this.lo, required this.hi, required this.span, required this.accent});
  final PoolStats? stats;
  final double lo, hi;
  final (double, double) span;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final s = stats;
    if (s == null || s.bpmCounts.isEmpty) return;
    final top = s.bpmCounts.reduce(math.max);
    if (top == 0) return;
    final range = span.$2 - span.$1;
    if (range <= 0) return;
    for (var i = 0; i < s.bpmCounts.length; i++) {
      final bpm = s.bpmFrom + s.bpmStep * i;
      if (bpm < span.$1 || bpm > span.$2) continue;
      final x = (bpm - span.$1) / range * size.width;
      final w = s.bpmStep / range * size.width - 1;
      final h = s.bpmCounts[i] / top * size.height;
      final lit = bpm + s.bpmStep > lo && bpm < hi;
      canvas.drawRect(Rect.fromLTWH(x, size.height - h, math.max(1, w), h),
          Paint()..color = lit ? accent.withValues(alpha: 0.6) : Console.faint.withValues(alpha: 0.35));
    }
  }

  @override
  bool shouldRepaint(_HistogramPainter old) => true;
}

/// The set over its time: where the shape wanted its energy (the line), where each
/// record is (the dots), and the tempo underneath.
class _SetChart extends StatelessWidget {
  const _SetChart({required this.set, required this.accent});
  final DjSet set;
  final Color accent;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _SetChartPainter(set, accent));
}

class _SetChartPainter extends CustomPainter {
  _SetChartPainter(this.set, this.accent);
  final DjSet set;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6));
    canvas.drawRRect(r, Paint()..color = Console.raised);
    final total = set.length.inMilliseconds.toDouble();
    if (total <= 0) return;
    double x(Duration at) => 6 + at.inMilliseconds / total * (size.width - 12);
    double y(double e) => 5 + (1 - e.clamp(0.0, 1.0)) * (size.height - 10);
    // The target: the house's curve over the set's time where it sent one, else each
    // slot's own target.
    final line = Path();
    if (set.curve.length >= 2) {
      for (var i = 0; i < set.curve.length; i++) {
        final o = Offset(6 + i / (set.curve.length - 1) * (size.width - 12), y(set.curve[i]));
        i == 0 ? line.moveTo(o.dx, o.dy) : line.lineTo(o.dx, o.dy);
      }
    } else {
      var started = false;
      for (final s in set.slots) {
        if (s.target == null) continue;
        final o = Offset(x(s.at), y(s.target!));
        started ? line.lineTo(o.dx, o.dy) : line.moveTo(o.dx, o.dy);
        started = true;
      }
    }
    canvas.drawPath(line, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = accent.withValues(alpha: 0.5));
    // Tempo, on its own scale.
    final bpms = [for (final s in set.slots) if (s.bpm != null) s.bpm!];
    if (bpms.length >= 2) {
      final lo = bpms.reduce(math.min) - 2, hi = bpms.reduce(math.max) + 2;
      final p = Path();
      var started = false;
      for (final s in set.slots) {
        if (s.bpm == null) continue;
        final o = Offset(x(s.at), 5 + (1 - (s.bpm! - lo) / (hi - lo)) * (size.height - 10));
        started ? p.lineTo(o.dx, o.dy) : p.moveTo(o.dx, o.dy);
        started = true;
      }
      canvas.drawPath(p, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Console.faint.withValues(alpha: 0.7));
    }
    for (final s in set.slots) {
      final e = s.energy;
      if (e == null) continue;
      canvas.drawCircle(Offset(x(s.at), y(e)), s.pinned ? 4 : 3, Paint()..color = s.pinned ? accent : Console.ink);
    }
  }

  @override
  bool shouldRepaint(_SetChartPainter old) => !identical(old.set, set);
}

/// A record's loudness against where the shape wanted it.
class _EnergyBar extends StatelessWidget {
  const _EnergyBar({required this.energy, required this.target, required this.accent, this.width = 54});
  final double? energy, target;
  final Color accent;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        height: 12,
        child: CustomPaint(painter: _EnergyBarPainter(energy, target, accent)),
      );
}

class _EnergyBarPainter extends CustomPainter {
  _EnergyBarPainter(this.energy, this.target, this.accent);
  final double? energy, target;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    canvas.drawRRect(RRect.fromLTRBR(0, mid - 2, size.width, mid + 2, const Radius.circular(2)), Paint()..color = Console.line);
    final e = energy;
    if (e != null) {
      canvas.drawRRect(RRect.fromLTRBR(0, mid - 2, size.width * e.clamp(0.0, 1.0), mid + 2, const Radius.circular(2)),
          Paint()..color = Console.quiet);
    }
    final t = target;
    if (t != null) {
      final x = size.width * t.clamp(0.0, 1.0);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), Paint()
        ..strokeWidth = 2
        ..color = accent);
    }
  }

  @override
  bool shouldRepaint(_EnergyBarPainter old) => old.energy != energy || old.target != target;
}

/// The move between two records: how well they fit and why, what the booth would
/// do, and a way to choose another.
class _MoveRow extends StatelessWidget {
  const _MoveRow({
    required this.booth,
    required this.from,
    required this.to,
    required this.fit,
    required this.why,
    required this.chosen,
    required this.onPick,
  });
  final Booth booth;
  final Track from, to;
  final double? fit;
  final String why;
  final MixPlan? chosen;
  final void Function(MixPlan?) onPick;

  @override
  Widget build(BuildContext context) {
    final auto = booth.auto;
    final accent = Theme.of(context).colorScheme.primary;
    final move = chosen ?? auto.previewOf(from, to);
    return InkWell(
      onTap: () => _pick(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(62, 2, 8, 2),
        child: Row(
          children: [
            FitMeter(fit: fit, width: 30, height: 3),
            const SizedBox(width: 8),
            Icon(move == null ? Icons.more_horiz : transitionIcon(move.kind), size: 13, color: chosen != null ? accent : Console.quiet),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                [
                  if (move != null) '${move.kind.label} · ${move.bars} bars',
                  if (why.isNotEmpty) why,
                ].join(' — '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Mag.typewriter(10, color: chosen != null ? accent : Console.faint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final options = await booth.auto.optionsFor(from, to);
    if (!context.mounted || options.isEmpty) return;
    final box = context.findRenderObject() as RenderBox?;
    final at = box?.localToGlobal(Offset.zero) ?? Offset.zero;
    final picked = await showMenu<MixPlan?>(
      context: context,
      color: Console.raised,
      position: RelativeRect.fromLTRB(at.dx + 60, at.dy + 24, at.dx + 60, at.dy),
      items: [
        for (final o in options)
          PopupMenuItem(
            value: o,
            child: Row(children: [
              Icon(transitionIcon(o.kind), size: 14, color: Console.quiet),
              const SizedBox(width: 8),
              Text('${o.kind.label} · ${o.bars}  ', style: Mag.typewriter(12, color: Console.ink)),
              Flexible(child: Text(o.why, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(10.5, color: Console.quiet))),
            ]),
          ),
        if (chosen != null)
          PopupMenuItem(value: null, child: Text('Let the booth choose', style: Mag.typewriter(12, color: Console.ink))),
      ],
    );
    if (picked != null || chosen != null) onPick(picked);
  }
}

/// Other records for a slot, as the house found them: tap one to put it there.
class _InsteadDialog extends StatelessWidget {
  const _InsteadDialog({required this.future, required this.of});
  final Future<List<SlotChoice>> future;
  final Track of;

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: Console.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Console.line)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 540),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('INSTEAD OF ${of.displayTitle.toUpperCase()}', maxLines: 1, overflow: TextOverflow.ellipsis, style: Console.label(9.5, color: Console.ink)),
              const SizedBox(height: 10),
              Flexible(
                child: FutureBuilder<List<SlotChoice>>(
                  future: future,
                  builder: (context, snap) {
                    if (snap.hasError) return Text('The house could not say: ${snap.error}', style: Mag.typewriter(11, color: Console.a));
                    final got = snap.data;
                    if (got == null) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
                    if (got.isEmpty) return Text('Nothing else fits here.', style: Mag.typewriter(11, color: Console.quiet));
                    return ListView.separated(
                      shrinkWrap: true,
                      itemCount: got.length,
                      separatorBuilder: (_, __) => Divider(height: 1, color: Console.line),
                      itemBuilder: (context, i) {
                        final c = got[i];
                        return InkWell(
                          onTap: () => Navigator.of(context).pop(c),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 7),
                            child: Row(children: [
                              Artwork(track: c.track, size: 32, radius: 3),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(c.track.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.title(13, color: Console.ink)),
                                  Text(c.why.isEmpty ? c.track.artistLine : c.why, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(9.5, color: Console.quiet)),
                                ]),
                              ),
                              if (c.camelot != null) Text(c.camelot!, style: Mag.typewriter(10, color: Console.quiet, bold: true)),
                              const SizedBox(width: 8),
                              if (c.bpm != null) Text(c.bpm!.toStringAsFixed(0), style: Mag.numerals(13, color: Console.quiet)),
                              const SizedBox(width: 10),
                              FitMeter(fit: c.fit / 2, width: 34),
                            ]),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: () => Navigator.of(context).pop(), child: Text('CLOSE', style: Console.label(9, color: Console.ink))),
              ),
            ]),
          ),
        ),
      );
}
