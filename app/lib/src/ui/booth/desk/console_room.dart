import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../api/models.dart';
import '../../../state/app_state.dart';
import '../../../state/booth/booth.dart';
import '../../../state/booth/deck.dart' as engine;
import '../../../worker/parts_jobs.dart';
import '../../dialogs.dart';
import '../../mag.dart';
import '../../snack.dart';
import '../../full_screen.dart';
import '../../theme.dart';
import 'console.dart';
import 'console_crate.dart';
import 'console_deck.dart';
import 'console_log.dart';
import 'console_mixer.dart';
import 'console_plan.dart';
import 'console_set.dart';
import 'console_waves.dart';

/// The booth on a desk: a console. The records' shapes across the top, a deck either
/// side of the mixer under them, the crate down the right, and the booth's own mixing
/// in the bar above it all.
class ConsoleRoom extends StatefulWidget {
  const ConsoleRoom({super.key, required this.booth, required this.keys});
  final Booth booth;

  /// The keyboard's shortcuts, for the "?" to show: key, what it does.
  final List<(String, String)> keys;

  @override
  State<ConsoleRoom> createState() => _ConsoleRoomState();
}

class _ConsoleRoomState extends State<ConsoleRoom> {
  bool _crate = true;
  engine.Deck? _for;

  /// The crate's open page, so the bar's parts light can open the list of parts.
  final _tab = ValueNotifier(CrateTab.queue);

  /// How wide the crate is: dragged by its edge, or widened to half the screen and
  /// back; kept between visits.
  double _crateWidth = 320;
  bool _wide = false;
  bool _logFolded = false;

  /// The Auto DJ's plan drawn out, in the place of the waveforms.
  bool _planView = false;

  static const _kWidth = 'muse.booth.crateWidth';
  static const _kWide = 'muse.booth.crateWide';
  static const _kLog = 'muse.booth.logFolded';
  static const _kPlan = 'muse.booth.planView';

  Booth get _b => widget.booth;
  late final AppState _app = context.read<AppState>();
  List<Track>? _queueSeen;

  @override
  void initState() {
    super.initState();
    unawaited(_remember());
    _app.addListener(_queueMoved);
    planViewToggles.addListener(_togglePlan);
    planPair.addListener(_pairAsked);
  }

  /// A pair was tapped in the set strip: the plan view, on that pair.
  void _pairAsked() {
    if (planPair.value != null && !_planView) {
      setState(() => _planView = true);
      unawaited(_keepLayout());
    }
  }

  Future<void> _remember() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _crateWidth = prefs.getDouble(_kWidth) ?? 320;
      _wide = prefs.getBool(_kWide) ?? false;
      _logFolded = prefs.getBool(_kLog) ?? false;
      _planView = prefs.getBool(_kPlan) ?? false;
    });
  }

  Future<void> _keepLayout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kWidth, _crateWidth);
    await prefs.setBool(_kWide, _wide);
    await prefs.setBool(_kLog, _logFolded);
    await prefs.setBool(_kPlan, _planView);
  }

  /// The queue changed — in the crate or anywhere else: the automix follows it.
  void _queueMoved() {
    final items = _app.player?.items;
    if (items == null || identical(items, _queueSeen)) return;
    _queueSeen = items;
    _b.auto.follow(items);
  }

  @override
  void dispose() {
    // Out of the booth, out of full screen: the rest of the app has its own chrome.
    if (fullScreen.value) unawaited(toggleFullScreen());
    _app.removeListener(_queueMoved);
    planViewToggles.removeListener(_togglePlan);
    planPair.removeListener(_pairAsked);
    planPair.value = null;
    _tab.dispose();
    super.dispose();
  }

  /// The crate's width on this screen: what was dragged or asked for, never so wide
  /// that the decks and the mixer have too little room.
  double _widthFor(double screen) {
    final most = (screen - 980).clamp(280.0, screen * 0.62);
    final want = _wide ? screen * 0.5 : _crateWidth;
    return want.clamp(280.0, most);
  }

  void _pick(engine.Deck d) => setState(() {
        _crate = true;
        _for = d;
      });

  void _load(engine.Deck d, Track t) {
    setState(() => _for = null);
    unawaited(_b.load(d, t));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Theme(
      data: MuseTheme.dark(app.palette),
      child: Builder(
        builder: (context) => Scaffold(
          backgroundColor: Console.ground,
          body: SafeArea(
            child: Column(
              children: [
                _bar(context),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: _room()),
                        if (_crate) ...[
                          _Edge(
                            onDrag: (dx) => setState(() {
                              final screen = MediaQuery.sizeOf(context).width;
                              _crateWidth = (_widthFor(screen) - dx).clamp(280.0, screen * 0.62);
                              _wide = false;
                            }),
                            onDone: _keepLayout,
                          ),
                          SizedBox(
                            width: _widthFor(MediaQuery.sizeOf(context).width),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                    flex: 3,
                                    child: ConsoleCrate(
                                      booth: _b,
                                      loadInto: _load,
                                      forDeck: _for,
                                      tab: _tab,
                                      wide: _wide,
                                      onWide: () {
                                        setState(() => _wide = !_wide);
                                        unawaited(_keepLayout());
                                      },
                                    )),
                                const SizedBox(height: 10),
                                if (_logFolded)
                                  ConsoleLog(booth: _b, folded: true, onFold: _fold)
                                else
                                  Expanded(
                                      flex: 2,
                                      child: ConsoleLog(booth: _b, onFold: _fold)),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _togglePlan() {
    setState(() => _planView = !_planView);
    unawaited(_keepLayout());
  }

  void _fold() {
    setState(() => _logFolded = !_logFolded);
    unawaited(_keepLayout());
  }

  Widget _room() => LayoutBuilder(builder: (context, c) {
        final waves = _planView
            ? (c.maxHeight * 0.42).clamp(240.0, 420.0)
            : (c.maxHeight * 0.3).clamp(150.0, 320.0);
        final mixer = (c.maxWidth * 0.2).clamp(230.0, 290.0);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
                height: waves,
                child: _planView ? ConsolePlan(booth: _b) : ConsoleWaves(booth: _b)),
            const SizedBox(height: 10),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: ConsoleDeck(booth: _b, deck: _b.a, onLoad: () => _pick(_b.a))),
                  const SizedBox(width: 10),
                  SizedBox(width: mixer, child: ConsoleMixer(booth: _b)),
                  const SizedBox(width: 10),
                  Expanded(child: ConsoleDeck(booth: _b, deck: _b.b, onLoad: () => _pick(_b.b))),
                ],
              ),
            ),
          ],
        );
      });

  Widget _bar(BuildContext context) {
    return SizedBox(
      height: 60,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 8, 0),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Console.quiet),
              tooltip: 'Back',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 2),
            _Mark(on: _b.live),
            const SizedBox(width: 22),
            Expanded(child: ConsoleSet(booth: _b)),
            const SizedBox(width: 12),
            if (_b.parts.separatesHere)
              _PartsLight(
                onTap: () => setState(() {
                  _crate = true;
                  _tab.value = CrateTab.parts;
                }),
              ),
            if (_b.taken.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.bookmark_add_outlined, color: Console.quiet),
                tooltip: 'Keep this mix',
                onPressed: () => _keep(context),
              ),
            IconButton(
              icon: Icon(Icons.insights, color: _planView ? Console.ink : Console.quiet),
              tooltip: _planView ? 'Back to the waveforms (P)' : "The Auto DJ's plan (P)",
              onPressed: _togglePlan,
            ),
            if (canGoFullScreen)
              ValueListenableBuilder<bool>(
                valueListenable: fullScreen,
                builder: (context, on, _) => IconButton(
                  icon: Icon(on ? Icons.fullscreen_exit : Icons.fullscreen,
                      color: on ? Console.ink : Console.quiet),
                  tooltip: on ? 'Leave full screen (F11)' : 'Full screen (F11)',
                  onPressed: () => unawaited(toggleFullScreen()),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.keyboard_outlined, color: Console.quiet),
              tooltip: 'Keys',
              onPressed: () => _showKeys(context),
            ),
            IconButton(
              icon: Icon(_crate ? Icons.view_sidebar : Icons.view_sidebar_outlined,
                  color: _crate ? Console.ink : Console.quiet),
              tooltip: _crate ? 'Hide the crate' : 'The crate',
              onPressed: () => setState(() => _crate = !_crate),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _keep(BuildContext context) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final d = DateTime.now();
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final name = await promptForName(context, 'Keep this mix', 'Mix · ${d.day} ${months[d.month - 1]}');
    if (name == null || name.trim().isEmpty) return;
    try {
      final made = await _b.keepMix(name.trim());
      await app.refreshPlaylists();
      messenger.say(snack(Text('"${made.name}" is in your library, with its moves')));
    } catch (e) {
      messenger.say(problem(e));
    }
  }

  void _showKeys(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Console.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Console.line)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('KEYS', style: Console.label(11, color: Console.ink)),
                const SizedBox(height: 14),
                for (final (key, what) in widget.keys)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 110,
                          child: Wrap(spacing: 4, children: [for (final k in key.split(' ')) _Cap(k)]),
                        ),
                        Expanded(child: Text(what, style: Mag.typewriter(12, color: Console.ink))),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Cap extends StatelessWidget {
  const _Cap(this.k);
  final String k;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
        decoration: BoxDecoration(
          color: Console.raised,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Console.line),
        ),
        child: Text(k, style: Mag.typewriter(11, color: Console.ink, bold: true)),
      );
}

/// WET◉WL, small, with BOOTH beside it — and ON AIR lit while the booth has the sound.
class _Mark extends StatelessWidget {
  const _Mark({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) {
    final style = Mag.headline(19, color: Colors.white, width: 125).copyWith(height: 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          color: MuseTheme.masthead,
          padding: const EdgeInsets.fromLTRB(6, 3, 6, 1),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('WET', style: style),
              Image.asset('assets/brand/ball.webp', width: 15, height: 15),
              Text('WL', style: style),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text('BOOTH', style: Console.label(11, color: Console.ink)),
        const SizedBox(width: 10),
        AnimatedOpacity(
          duration: const Duration(milliseconds: 300),
          opacity: on ? 1 : 0.25,
          child: Container(
            padding: const EdgeInsets.fromLTRB(5, 2, 5, 1),
            decoration: BoxDecoration(
              border: Border.all(color: on ? Console.a : Console.faint),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text('ON AIR', style: Console.label(7.5, color: on ? Console.a : Console.faint)),
          ),
        ),
      ],
    );
  }
}


/// The bar's light for records being taken apart here: how far the one in hand has got
/// and how many wait behind it. Out when nothing is happening, and READY for a moment
/// when the last one is done. Pressed, it opens the list.
class _PartsLight extends StatefulWidget {
  const _PartsLight({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_PartsLight> createState() => _PartsLightState();
}

class _PartsLightState extends State<_PartsLight> {
  static const _readyFor = Duration(seconds: 8);
  Timer? _out;

  @override
  void initState() {
    super.initState();
    partsJobs.addListener(_changed);
  }

  @override
  void dispose() {
    partsJobs.removeListener(_changed);
    _out?.cancel();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final now = partsJobs.running.firstOrNull;
    final waiting = partsJobs.waiting.length;
    final last = partsJobs.ready.firstOrNull;
    final since = last?.finished == null ? null : DateTime.now().difference(last!.finished!);
    final justReady = now == null && waiting == 0 && since != null && since < _readyFor;
    if (justReady) {
      _out?.cancel();
      _out = Timer(_readyFor - since, _changed);
    }
    if (now == null && waiting == 0 && !justReady) return const SizedBox.shrink();

    final p = now?.stage == PartsStage.separating ? now!.progress : null;
    final word = now == null
        ? justReady
            ? 'READY'
            : 'WAITING'
        : switch (now.stage) {
            PartsStage.fetching => 'FETCHING',
            PartsStage.gettingSeparator => 'SETTING UP',
            _ => p == null ? 'SPLITTING' : '${(p * 100).floor()}%',
          };
    final tip = now != null
        ? '${now.title} · ${stageLine(now)}${waiting > 0 ? ' · $waiting waiting' : ''}'
        : justReady
            ? 'Parts ready: ${last!.title}'
            : '$waiting waiting to be taken apart';
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: tip,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            height: 28,
            padding: const EdgeInsets.fromLTRB(9, 0, 10, 0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: justReady ? accent : Console.line),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (now != null)
                  SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                      value: now.stage == PartsStage.fetching && now.total == null ? null : now.progress,
                      strokeWidth: 2,
                      color: accent,
                      backgroundColor: Console.line,
                    ),
                  )
                else
                  Icon(justReady ? Icons.check : Icons.hourglass_empty,
                      size: 14, color: justReady ? accent : Console.quiet),
                const SizedBox(width: 7),
                Icon(Icons.call_split, size: 13, color: Console.quiet),
                const SizedBox(width: 5),
                Text(word, style: Console.label(9, color: justReady ? accent : Console.ink)),
                if (now != null && waiting > 0) ...[
                  const SizedBox(width: 6),
                  Text('+$waiting', style: Console.label(9, color: Console.quiet)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}


/// The crate's edge: dragged, the crate is wider or narrower.
class _Edge extends StatefulWidget {
  const _Edge({required this.onDrag, required this.onDone});
  final void Function(double dx) onDrag;
  final Future<void> Function() onDone;

  @override
  State<_Edge> createState() => _EdgeState();
}

class _EdgeState extends State<_Edge> {
  bool _over = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        onEnter: (_) => setState(() => _over = true),
        onExit: (_) => setState(() => _over = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
          onHorizontalDragEnd: (_) => unawaited(widget.onDone()),
          child: SizedBox(
            width: 10,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 2,
                height: 48,
                decoration: BoxDecoration(
                  color: _over ? Console.quiet : Console.line,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ),
          ),
        ),
      );
}
