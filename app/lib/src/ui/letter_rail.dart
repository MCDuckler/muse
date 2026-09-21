import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mag.dart';
import 'theme.dart';

/// The alphabet down the side of a long list.
///
/// Two thousand records is a long way to scroll to reach the Ts. A finger put on the
/// rail goes to the letter under it, and dragged, to each letter it passes; a sticker
/// beside the finger says which, large enough to read past the thumb that is covering
/// the rail itself.
///
/// It knows nothing about lists: it is told the letters there are and says which one
/// was asked for. Going there — fetching that far, working out how far down that is —
/// belongs to the page.
class LetterRail extends StatefulWidget {
  const LetterRail({super.key, required this.letters, required this.onLetter});

  /// Only the letters the list actually has anything under, in its order.
  final List<String> letters;
  final ValueChanged<String> onLetter;

  @override
  State<LetterRail> createState() => _LetterRailState();
}

class _LetterRailState extends State<LetterRail> {
  String? _held;
  double _at = 0;

  void _touch(double y, double height) {
    final letters = widget.letters;
    if (letters.isEmpty || height <= 0) return;
    final i = (y / height * letters.length).floor().clamp(0, letters.length - 1);
    final letter = letters[i];
    setState(() => _at = y.clamp(0.0, height));
    if (letter == _held) return;
    setState(() => _held = letter);
    HapticFeedback.selectionClick();
    widget.onLetter(letter);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final letters = widget.letters;
    if (letters.length < 2) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, box) {
      // As tall as the letters need and no taller than there is: on a short screen
      // they close up, and below a size anybody could hit, every other one is a dot.
      final room = box.maxHeight;
      final each = (room / letters.length).clamp(0.0, 18.0);
      final height = each * letters.length;
      final thin = each < 11;
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          height: height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Semantics(
                label: 'Jump to a letter',
                slider: true,
                value: _held ?? '',
                // Heard as the finger lands, not once it has been decided what kind
                // of gesture this is: a tap waits a tenth of a second to see whether it
                // is a drag, and a rail that answers late feels broken. The detector
                // is only there to claim the drag, so the list underneath stays put.
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) => _touch(e.localPosition.dy, height),
                  onPointerMove: (e) => _touch(e.localPosition.dy, height),
                  onPointerUp: (_) => setState(() => _held = null),
                  onPointerCancel: (_) => setState(() => _held = null),
                  child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (_) {},
                  onTap: () {},
                  child: SizedBox(
                    width: 26,
                    child: Column(
                      children: [
                        for (final (i, l) in letters.indexed)
                          SizedBox(
                            height: each,
                            child: Center(
                              child: Text(
                                thin && i.isOdd ? '·' : l,
                                textScaler: TextScaler.noScaling,
                                style: Mag.flag(each.clamp(7.0, 10.0),
                                    color: l == _held
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  ),
                ),
              ),
              if (_held != null)
                Positioned(
                  right: 40,
                  top: (_at - 30).clamp(-6.0, height - 54),
                  child: IgnorePointer(
                    child: Transform.rotate(
                      angle: -0.06,
                      child: Container(
                        width: 60,
                        height: 60,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: MuseTheme.masthead,
                          boxShadow: [
                            BoxShadow(
                                color: Colors.black.withValues(alpha: 0.25),
                                blurRadius: 8,
                                offset: const Offset(2, 3)),
                          ],
                        ),
                        child: Text(_held!,
                            textScaler: TextScaler.noScaling,
                            style: Mag.headline(40, color: Colors.white)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}


/// What a page needs to go to a letter: the letters, the list's scroll position, and
/// the going itself.
///
/// The page says how to fetch as far as a row ([reach]) and how far down the screen a
/// row is ([pixelsTo]); this keeps the rest — asking the server where the letters
/// start, and, while a finger is dragged down the rail through six letters, going only
/// to the one it ends on rather than to all six in turn.
class LetterJump {
  LetterJump({required this.ask, required this.reach, required this.pixelsTo});

  final Future<List<({String letter, int offset})>> Function() ask;
  final Future<void> Function(int index) reach;
  final double Function(int index) pixelsTo;

  final scroll = ScrollController();
  final letters = ValueNotifier<List<({String letter, int offset})>>(const []);
  String? _wanted;

  Future<void> load() async {
    try {
      letters.value = await ask();
    } catch (_) {
      // A server from before there was an index: no rail, and the list as it was.
      letters.value = const [];
    }
  }

  Future<void> go(String letter) async {
    final to = letters.value.where((l) => l.letter == letter).firstOrNull;
    if (to == null) return;
    _wanted = letter;
    await reach(to.offset);
    if (_wanted != letter || !scroll.hasClients) return;
    _settleOn(letter, pixelsTo(to.offset), 6);
  }

  /// Put the list there once it is long enough to be put there.
  ///
  /// A list that builds only the rows near the screen does not measure itself again
  /// because more rows exist: it finds out how long it is when it next scrolls. So
  /// "as far as it goes" is still where the old list ended, and going straight to row
  /// 1,640 stops at row 200. Going to the end it knows about is what makes it look
  /// again; after that frame it knows better, and the next step is the letter — or, if
  /// the end has stopped moving, the end, because that is all there is.
  void _settleOn(String letter, double pixels, int tries, [double? wasMost]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_wanted != letter || !scroll.hasClients) return;
      final most = scroll.position.maxScrollExtent;
      if (most >= pixels || tries <= 0 || most == wasMost) {
        scroll.jumpTo(pixels.clamp(0.0, most));
        return;
      }
      scroll.jumpTo(most);
      _settleOn(letter, pixels, tries - 1, most);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void dispose() {
    scroll.dispose();
    letters.dispose();
  }
}

/// A list with the alphabet down its side, when there is an alphabet to show.
class WithLetters extends StatelessWidget {
  const WithLetters({super.key, required this.jump, required this.show, required this.child});

  final LetterJump jump;

  /// Only a list in name order, unfiltered, has letters that mean anything.
  final bool show;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.passthrough,
        children: [
          child,
          if (show)
            Positioned(
              right: 0,
              top: 8,
              // Clear of the player bar at the bottom of every page.
              bottom: 150,
              child: ValueListenableBuilder(
                valueListenable: jump.letters,
                builder: (context, letters, _) => LetterRail(
                  letters: [for (final l in letters) l.letter],
                  onLetter: jump.go,
                ),
              ),
            ),
        ],
      );
}
