import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../api/models.dart';
import '../../../state/app_state.dart';
import '../../../state/booth/booth.dart';
import '../../../state/booth/deck.dart' as engine;
import '../../dialogs.dart';
import '../../snack.dart';
import '../../theme.dart';
import '../desk/console.dart';
import '../desk/console_crate.dart';
import '../desk/console_log.dart';
import '../desk/console_plan.dart';
import '../desk/console_room.dart' show BoothMark;
import '../desk/console_set.dart';
import '../desk/console_waves.dart';
import 'phone_auto.dart';
import 'phone_deck.dart';
import 'phone_mixer.dart';

/// The booth on a phone: the same console as the desk's, folded to one column. The
/// two records' shapes across the top, the decks side by side under them, the mixer
/// across, the Auto DJ, the log — and the crate, the set and the plan, which open
/// over the room when they are wanted, since a phone has no room beside it.
class PhoneRoom extends StatefulWidget {
  const PhoneRoom({super.key, required this.booth});
  final Booth booth;

  @override
  State<PhoneRoom> createState() => _PhoneRoomState();
}

class _PhoneRoomState extends State<PhoneRoom> {
  final _tab = ValueNotifier(CrateTab.queue);
  late final AppState _app = context.read<AppState>();
  List<Track>? _queueSeen;
  bool _planOpen = false;

  Booth get _b => widget.booth;

  @override
  void initState() {
    super.initState();
    _app.addListener(_queueMoved);
    planPair.addListener(_pairAsked);
  }

  @override
  void dispose() {
    _app.removeListener(_queueMoved);
    planPair.removeListener(_pairAsked);
    planPair.value = null;
    _tab.dispose();
    super.dispose();
  }

  /// The queue changed — in the crate or anywhere else: the automix follows it.
  void _queueMoved() {
    final items = _app.player?.items;
    if (items == null || identical(items, _queueSeen)) return;
    _queueSeen = items;
    _b.auto.follow(items);
  }

  /// A pair was tapped in the set: the plan, on that pair, over the set.
  void _pairAsked() {
    if (planPair.value != null && !_planOpen) unawaited(_openPlan());
  }

  Future<void> _sheet(Widget child, {double height = 0.88}) {
    final app = context.read<AppState>();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Console.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (sheet) => Theme(
        data: MuseTheme.dark(app.palette),
        child: SizedBox(
          height: MediaQuery.sizeOf(sheet).height * height,
          child: Padding(padding: const EdgeInsets.fromLTRB(8, 10, 8, 8), child: child),
        ),
      ),
    );
  }

  Future<void> _openCrate([engine.Deck? forDeck]) => _sheet(ConsoleCrate(
        booth: _b,
        forDeck: forDeck,
        tab: _tab,
        loadInto: (d, t) {
          Navigator.of(context).pop();
          unawaited(_b.load(d, t));
        },
      ));

  Future<void> _openSet() => _sheet(ConsoleSetView(booth: _b), height: 0.52);

  Future<void> _openPlan() async {
    _planOpen = true;
    await _sheet(ConsolePlan(booth: _b), height: 0.78);
    _planOpen = false;
    planPair.value = null;
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
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                    children: [
                      SizedBox(height: 164, child: ConsoleWaves(booth: _b)),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: PhoneDeck(booth: _b, deck: _b.a, onLoad: () => _openCrate(_b.a))),
                          const SizedBox(width: 8),
                          Expanded(child: PhoneDeck(booth: _b, deck: _b.b, onLoad: () => _openCrate(_b.b))),
                        ],
                      ),
                      const SizedBox(height: 8),
                      PhoneMixer(booth: _b),
                      const SizedBox(height: 8),
                      PhoneAutoCard(booth: _b, onSet: _openSet, onPlan: _openPlan),
                      const SizedBox(height: 8),
                      SizedBox(height: 200, child: ConsoleLog(booth: _b)),
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

  Widget _bar(BuildContext context) => SizedBox(
        height: 52,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Console.quiet),
              tooltip: 'Back',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            BoothMark(on: _b.live),
            const Spacer(),
            if (_b.taken.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.bookmark_add_outlined, color: Console.quiet),
                tooltip: 'Keep this mix',
                onPressed: () => _keep(context),
              ),
            IconButton(
              icon: const Icon(Icons.inventory_2_outlined, color: Console.ink),
              tooltip: 'The crate',
              onPressed: () => _openCrate(),
            ),
            const SizedBox(width: 4),
          ],
        ),
      );

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
}
