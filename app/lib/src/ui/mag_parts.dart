import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'mag.dart';
import 'theme.dart';

/// The pieces a magazine page is pasted up from: the masthead, a sticker, a cut-out
/// with tape on it, a kicker. Loud on purpose, and so used on Home, the feature pages
/// and the player — never in a list, where they would be twenty thousand stickers.

/// This week's issue number: the week of the year, the way a weekly counts.
int issueNumber(DateTime day) {
  // ISO 8601: the week with the year's first Thursday in it is week one.
  final d = DateTime.utc(day.year, day.month, day.day);
  final thursday = d.add(Duration(days: 4 - d.weekday));
  final yearStart = DateTime.utc(thursday.year, 1, 1);
  return ((thursday.difference(yearStart).inDays) / 7).floor() + 1;
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

/// The date as a cover prints it: 21 Sep 2026.
String coverDate(DateTime day) => '${day.day} ${_months[day.month - 1]} ${day.year}';

/// WET◉WL, knocked out of the red box, with the disco ball standing in for the O.
class Masthead extends StatelessWidget {
  const Masthead({super.key, this.size = 44, this.trailing});

  /// The height of the letters.
  final double size;

  /// Whatever sits at the right-hand end of the band: the price, the issue.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final style = Mag.headline(size, color: Colors.white, width: 125)
        .copyWith(height: 1.0, letterSpacing: -size * 0.035);
    // A masthead is the logo, not text to be read: it keeps its size when the phone's
    // type is turned up, and on a screen too narrow for it, it shrinks to fit rather
    // than running off the edge.
    return Semantics(
      header: true,
      label: 'WetOwl',
      child: ExcludeSemantics(
        child: MediaQuery.withNoTextScaling(
          child: Container(
            color: MuseTheme.masthead,
            padding:
                EdgeInsets.fromLTRB(size * 0.28, size * 0.10, size * 0.28, size * 0.02),
            child: Row(
              children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('WET', style: style),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: size * 0.02),
                          child: Image.asset('assets/brand/ball.webp',
                              width: size * 0.80, height: size * 0.80),
                        ),
                        Text('WL', style: style),
                      ],
                    ),
                  ),
                ),
                if (trailing != null) ...[
                  SizedBox(width: size * 0.3),
                  trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A starburst sticker slapped on a page: "3 NEW", "LIVE", "No.1".
class Starburst extends StatelessWidget {
  const Starburst({
    super.key,
    required this.child,
    this.size = 72,
    this.colour = MuseTheme.highlighter,
    this.points = 16,
    this.turn = 0.2,
  });

  final Widget child;
  final double size;
  final Color colour;
  final int points;

  /// How crooked it was stuck on, in radians.
  final double turn;

  @override
  Widget build(BuildContext context) => Transform.rotate(
        angle: turn,
        child: SizedBox.square(
          dimension: size,
          child: CustomPaint(
            painter: _Burst(colour: colour, points: points),
            child: Center(child: child),
          ),
        ),
      );
}

class _Burst extends CustomPainter {
  _Burst({required this.colour, required this.points});

  final Color colour;
  final int points;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final outer = size.shortestSide / 2;
    final inner = outer * 0.74;
    final path = Path();
    for (var i = 0; i < points * 2; i++) {
      final r = i.isEven ? outer : inner;
      final a = math.pi * i / points - math.pi / 2;
      final p = c + Offset(math.cos(a), math.sin(a)) * r;
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    canvas.drawShadow(path, Colors.black, 2, false);
    canvas.drawPath(path, Paint()..color = colour);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = MuseTheme.ink,
    );
  }

  @override
  bool shouldRepaint(_Burst old) => old.colour != colour || old.points != points;
}

/// Words on a sticker: black, condensed, stacked tight.
class StickerText extends StatelessWidget {
  const StickerText(this.big, {super.key, this.small, this.colour = MuseTheme.ink});

  final String big;
  final String? small;
  final Color colour;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(big.toUpperCase(),
              textAlign: TextAlign.center,
              style: Mag.headline(18, color: colour, width: 75).copyWith(height: 0.9)),
          if (small != null)
            Text(small!.toUpperCase(),
                textAlign: TextAlign.center,
                style: Mag.headline(10, color: colour, width: 75).copyWith(height: 0.9)),
        ],
      );
}

/// A picture cut out and pasted down: a white border, a slight tilt, a shadow, and —
/// if [taped] — a strip of tape across the top holding it on.
class CutOut extends StatelessWidget {
  const CutOut({super.key, required this.child, this.turn = -0.04, this.taped = false});

  final Widget child;

  /// How crooked it was pasted, in radians.
  final double turn;
  final bool taped;

  @override
  Widget build(BuildContext context) => Transform.rotate(
        angle: turn,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.28),
                    blurRadius: 10,
                    offset: const Offset(2, 4),
                  ),
                ],
              ),
              child: Padding(padding: const EdgeInsets.all(5), child: child),
            ),
            if (taped)
              Positioned(
                top: -10,
                left: 0,
                right: 0,
                child: Center(
                  child: Transform.rotate(
                    angle: 0.07,
                    child: Container(
                      width: 70,
                      height: 20,
                      decoration: BoxDecoration(
                        color: const Color(0xB8F6ECC4),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.10),
                            blurRadius: 2,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}

/// A kicker: the small expanded label over a headline. Set in capitals, in the red.
class Kicker extends StatelessWidget {
  const Kicker(this.text, {super.key, this.colour});

  final String text;
  final Color? colour;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: Mag.flag(10, color: colour ?? Theme.of(context).colorScheme.primary),
      );
}

/// A section flag: a black bar with the section's name knocked out of it.
class SectionFlag extends StatelessWidget {
  const SectionFlag(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      header: true,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          color: scheme.onSurface,
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 3),
          child: Text(text.toUpperCase(), style: Mag.flag(12, color: scheme.surface)),
        ),
      ),
    );
  }
}
