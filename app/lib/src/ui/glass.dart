import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'mirror_ball.dart' show RoomLight, RoomLightScope;

/// A translucent, blurred surface.
///
/// Used only where something genuinely sits *over* content — the player bar, the
/// navigation bar, the now-playing controls. Applying it everywhere would be fog
/// rather than depth, and blur is not free to render.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.blur = 24,
    this.opacity = 0.72,
    this.borderRadius,
    this.topBorder = true,
    this.padding = EdgeInsets.zero,
    this.sheen = false,
  });

  final Widget child;
  final double blur;
  final double opacity;
  final BorderRadius? borderRadius;
  final bool topBorder;
  final EdgeInsetsGeometry padding;

  /// A pane of glass standing in the room, rather than a panel on the page: a thread
  /// of light along its top edge, a soft sheen down it — and, where the room's light
  /// is moving (RoomLightScope), each beam's reflection sliding across it and its edge
  /// lit on the side nearest the beam.
  final bool sheen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = borderRadius ?? BorderRadius.zero;
    final opacity = kIsWeb ? (this.opacity + 0.22).clamp(0.0, 1.0) : this.opacity;
    // No blur at all in a browser.
    //
    // A backdrop filter reads back what has already been drawn and blurs it into a
    // surface of its own — every frame, for every panel that has one. There are two on
    // every screen here: the player bar and the row of tabs under it. On a phone that
    // is expensive; inside Safari on an iPhone it is a page being reloaded out from
    // under whoever was using it, because the tab's whole budget covers the engine,
    // the canvas and these buffers together.
    //
    // What is left is the panel itself, a little more solid to make up for the blur
    // that is not behind it. Nobody looking at it would say what is missing; everybody
    // noticed the crash.
    final sigma = kIsWeb ? 0.0 : blur;

    final pane = ClipRRect(
      borderRadius: radius,
      // An opaque ground under the blur, so a dropped backdrop sample shows the
      // surface rather than nothing.
      //
      // This is where the white blinking came from. A BackdropFilter reads what has
      // already been composited behind it, and when the layer tree above it changes —
      // a route settling, the record stage gaining or losing a repaint boundary — it
      // can be handed a frame with nothing in it. A 55%-opaque panel over nothing is a
      // white flash across the controls, which is exactly what it looked like.
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surface.withValues(alpha: opacity),
                borderRadius: radius,
              ),
            ),
          ),
      _MaybeBlurred(
        sigma: sigma,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: opacity),
            borderRadius: radius,
            border: topBorder
                ? Border(
                    top: BorderSide(
                      color: scheme.onSurface.withValues(alpha: 0.08),
                    ),
                  )
                : Border.all(color: scheme.onSurface.withValues(alpha: 0.08)),
          ),
          // ListTile paints its ink and selection on the nearest Material ancestor,
          // and the DecoratedBox above would hide both. A transparent Material gives
          // those effects somewhere to land without adding another colour layer.
          child: Material(
            type: MaterialType.transparency,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
          if (sheen) Positioned.fill(child: _Sheen(radius: radius)),
        ],
      ),
    );
    if (!sheen) return pane;
    // A pane standing in front of the page has a shadow under it: soft and low, so
    // it reads as a few millimetres off the wall rather than floating.
    final dark = scheme.brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.32 : 0.14), blurRadius: 26, offset: const Offset(0, 12)),
          BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.20 : 0.08), blurRadius: 5, offset: const Offset(0, 2)),
        ],
      ),
      child: pane,
    );
  }
}

/// The glass's own look, and the room's light on it. See GlassSurface.sheen.
class _Sheen extends StatefulWidget {
  const _Sheen({required this.radius});
  final BorderRadius radius;

  @override
  State<_Sheen> createState() => _SheenState();
}

class _SheenState extends State<_Sheen> {
  RoomLight? _room;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _room = RoomLightScope.maybeOf(context);
  }

  @override
  void dispose() {
    _room?.unplace(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: CustomPaint(
          painter: _SheenPainter(
            radius: widget.radius,
            dark: Theme.of(context).brightness == Brightness.dark,
            room: _room,
            placeAs: this,
            box: () => context.findRenderObject() as RenderBox?,
          ),
        ),
      );
}

/// A pane of thick glass. What makes glass read as glass is its edge: light bends
/// through the thickness of it, so there is a bright band just inside the rim, a
/// crisp thread of highlight along the top and the lit side, and a darker line where
/// the edge turns away. Then the surface: a soft fall of sheen from the top, one
/// long diagonal band of caustic light, and a little shadow gathering along the
/// bottom inside. And the room on it: each head's reflection sliding across, the
/// ball's spots as sharp glints, the rim lit towards the beam.
class _SheenPainter extends CustomPainter {
  _SheenPainter({required this.radius, required this.dark, required this.room, required this.placeAs, required this.box})
      : super(repaint: room);
  final BorderRadius radius;
  final bool dark;
  final RoomLight? room;
  final Object placeAs;
  final RenderBox? Function() box;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rr = radius.toRRect(rect);
    final b = box();
    final r = room;
    if (r != null && b != null && b.hasSize) {
      final tl = b.localToGlobal(Offset.zero);
      r.place(placeAs, rr.shift(tl));
    }
    canvas.save();
    canvas.clipRRect(rr);

    // The surface.
    canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: dark ? 0.10 : 0.55),
              Colors.white.withValues(alpha: dark ? 0.02 : 0.15),
              Colors.white.withValues(alpha: 0.0),
              Colors.black.withValues(alpha: dark ? 0.12 : 0.05),
            ],
            stops: const [0.0, 0.35, 0.7, 1.0],
          ).createShader(rect));
    // One long caustic across it, the way a pane catches the room's light.
    canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: const Alignment(-1, -1),
            end: const Alignment(1, 1),
            colors: [
              Colors.white.withValues(alpha: 0.0),
              Colors.white.withValues(alpha: dark ? 0.06 : 0.22),
              Colors.white.withValues(alpha: 0.0),
              Colors.white.withValues(alpha: dark ? 0.03 : 0.10),
              Colors.white.withValues(alpha: 0.0),
            ],
            stops: const [0.15, 0.32, 0.45, 0.72, 0.85],
          ).createShader(rect));

    // The edge: the thickness of the glass, lit through. A band inside the rim,
    // brighter towards the top-left where the room's own light comes from.
    final band = (size.shortestSide * 0.09).clamp(6.0, 14.0);
    canvas.drawRRect(
        rr.deflate(band / 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = band
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, band * 0.45)
          ..shader = LinearGradient(
            begin: const Alignment(-1, -1),
            end: const Alignment(1, 1),
            colors: [
              Colors.white.withValues(alpha: dark ? 0.20 : 0.55),
              Colors.white.withValues(alpha: dark ? 0.04 : 0.15),
              Colors.white.withValues(alpha: dark ? 0.12 : 0.35),
            ],
          ).createShader(rect));
    // The thread of highlight along the rim, and the darker turn of the edge inside it.
    canvas.drawRRect(
        rr.deflate(0.75),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..shader = LinearGradient(
            begin: const Alignment(-0.6, -1),
            end: const Alignment(0.6, 1),
            colors: [
              Colors.white.withValues(alpha: dark ? 0.55 : 0.95),
              Colors.white.withValues(alpha: dark ? 0.12 : 0.4),
              Colors.white.withValues(alpha: dark ? 0.30 : 0.7),
            ],
          ).createShader(rect));
    canvas.drawRRect(
        rr.deflate(2.2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.black.withValues(alpha: dark ? 0.22 : 0.08));

    // The room's light on the glass.
    if (r != null && r.life > 0) {
      final reach = size.longestSide;
      final blend = r.onPaper ? BlendMode.srcOver : BlendMode.plus;
      for (final (i, h) in r.heads.indexed) {
        final at = b == null ? h.at : b.globalToLocal(h.at);
        final colour = r.colours.length > i ? r.colours[i] : Colors.white;
        final a = r.life * h.level;
        // The beam's reflection: broad and soft, with a hot lamp-shaped heart
        // stretched the way the beam leans.
        canvas.drawCircle(
            at,
            reach * 0.55,
            Paint()
              ..blendMode = blend
              ..shader = RadialGradient(colors: [
                Color.lerp(colour, Colors.white, 0.6)!.withValues(alpha: (r.onPaper ? 0.30 : 0.16) * a),
                colour.withValues(alpha: (r.onPaper ? 0.10 : 0.05) * a),
                colour.withValues(alpha: 0),
              ], stops: const [0.0, 0.5, 1.0]).createShader(Rect.fromCircle(center: at, radius: reach * 0.55)));
        canvas.save();
        canvas.translate(at.dx, at.dy);
        canvas.rotate(h.lean);
        canvas.scale(1.6, 1);
        canvas.drawCircle(
            Offset.zero,
            reach * 0.05,
            Paint()
              ..blendMode = blend
              ..color = Colors.white.withValues(alpha: (r.onPaper ? 0.5 : 0.42) * a)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, reach * 0.035));
        canvas.restore();
        // The edge nearest the light, lit through its thickness.
        canvas.drawRRect(
            rr.deflate(1.2),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.2
              ..blendMode = blend
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.2)
              ..shader = RadialGradient(colors: [
                Colors.white.withValues(alpha: (r.onPaper ? 0.9 : 0.85) * a),
                Colors.white.withValues(alpha: 0),
              ]).createShader(Rect.fromCircle(center: at, radius: reach * 0.9)));
      }
      // The ball's spots on the glass: a pane throws the lamp straight back, so each
      // is a sharp glint rather than a soft square — small, bright, and gone as it
      // passes.
      if (b != null) {
        final glint = Paint()..blendMode = blend;
        for (final s in r.spots) {
          // Not every tile: a pane throws back the few that hit it square.
          if (s.lamp == 2 || s.tile % 3 == 1) continue;
          final at = b.globalToLocal(s.at);
          if (!rect.contains(at)) continue;
          final a = (0.7 / (s.far * s.far)) * r.life;
          if (a < 0.04) continue;
          final colour = r.lamps.length > s.lamp ? r.lamps[s.lamp] : Colors.white;
          canvas.drawCircle(
              at,
              s.wide * 0.55,
              glint
                ..color = colour.withValues(alpha: (a * 0.35).clamp(0.0, 1.0))
                ..maskFilter = MaskFilter.blur(BlurStyle.normal, s.wide * 0.6));
          canvas.drawCircle(
              at,
              s.wide * 0.22,
              glint
                ..color = Color.lerp(colour, Colors.white, 0.7)!.withValues(alpha: a.clamp(0.0, 1.0))
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.5));
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SheenPainter old) => old.radius != radius || old.dark != dark || old.room != room;
}

/// A blur, or nothing at all where one cannot be afforded.
class _MaybeBlurred extends StatelessWidget {
  const _MaybeBlurred({required this.sigma, required this.child});
  final double sigma;
  final Widget child;

  @override
  Widget build(BuildContext context) => sigma <= 0
      ? child
      : BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: child,
        );
}

/// The wash of colour behind the now-playing screen, taken from the cover.
///
/// This is what makes a player feel like it is *about* the record rather than a list
/// with a picture on it. The colour comes from the server, which already has the image
/// decoded, so the client never pays to analyse artwork.
class AmbientBackdrop extends StatelessWidget {
  const AmbientBackdrop({
    super.key,
    required this.colour,
    required this.child,
    this.behind,
  });

  final Color? colour;
  final Widget child;

  /// Drawn over the wash and under the content, filling the same box. A wrapper around
  /// [child] would change the constraints it is laid out with; this does not.
  final Widget? behind;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = colour ?? scheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Stack(
      children: [
        Positioned.fill(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.alphaBlend(
                      tint.withValues(alpha: isDark ? 0.42 : 0.28), scheme.surface),
                  Color.alphaBlend(
                      tint.withValues(alpha: isDark ? 0.12 : 0.08), scheme.surface),
                  scheme.surface,
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
          ),
        ),
        if (behind != null) Positioned.fill(child: behind!),
        child,
      ],
    );
  }
}

/// Parses the server's `#rrggbb`. Returns null rather than guessing, so callers can
/// fall back to the theme instead of rendering a wrong colour confidently.
Color? parseHexColour(String? hex) {
  if (hex == null || hex.length != 7 || !hex.startsWith('#')) return null;
  final value = int.tryParse(hex.substring(1), radix: 16);
  return value == null ? null : Color(0xFF000000 | value);
}
