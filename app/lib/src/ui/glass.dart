import 'dart:ui';
import 'dart:ui' as ui;

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
          if (!sheen)
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
                // ListTile paints its ink and selection on the nearest Material
                // ancestor, and the DecoratedBox above would hide both. A transparent
                // Material gives those effects somewhere to land without adding
                // another colour layer.
                child: Material(
                  type: MaterialType.transparency,
                  child: Padding(padding: padding, child: child),
                ),
              ),
            )
          else ...[
            // A pane of glass: the room behind it blurred through its body, and bent
            // through its edge — a band just inside the rim where the backdrop is seen
            // a little magnified, which is what the thickness of glass does to what
            // is behind it, and the one thing that says thick glass rather than
            // frosted film.
            Positioned.fill(
              child: _MaybeBlurred(
                sigma: sigma,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: opacity),
                    borderRadius: radius,
                  ),
                ),
              ),
            ),
            if (sigma > 0) Positioned.fill(child: _LensEdge(radius: radius)),
            Material(
              type: MaterialType.transparency,
              child: Padding(padding: padding, child: child),
            ),
            Positioned.fill(child: _Sheen(radius: radius)),
          ],
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

/// The edge of a thick pane: the backdrop seen through it a little magnified and
/// softened, in a band just inside the rim.
class _LensEdge extends StatelessWidget {
  const _LensEdge({required this.radius});
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        if (size.isEmpty) return const SizedBox.shrink();
        final band = (size.shortestSide * 0.10).clamp(7.0, 16.0);
        final cx = size.width / 2, cy = size.height / 2;
        // Scaled about the middle of the pane, so the edge shows what lies a little
        // further in — the way a lens at the rim pulls the picture outward.
        final lens = (Matrix4.identity()
              ..translateByDouble(cx, cy, 0, 1)
              ..scaleByDouble(1.09, 1.09, 1, 1)
              ..translateByDouble(-cx, -cy, 0, 1))
            .storage;
        return ClipPath(
          clipper: _Ring(radius: radius, band: band),
          child: BackdropFilter(
            filter: ImageFilter.compose(
              outer: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
              inner: ImageFilter.matrix(lens, filterQuality: FilterQuality.medium),
            ),
            child: const SizedBox.expand(),
          ),
        );
      });
}

class _Ring extends CustomClipper<Path> {
  const _Ring({required this.radius, required this.band});
  final BorderRadius radius;
  final double band;

  @override
  Path getClip(Size size) {
    final outer = radius.toRRect(Offset.zero & size);
    return Path.combine(PathOperation.difference, Path()..addRRect(outer), Path()..addRRect(outer.deflate(band)));
  }

  @override
  bool shouldReclip(_Ring old) => old.radius != radius || old.band != band;
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

    // The surface: nearly nothing. Glass is what is behind it; a wash of white over
    // it is frosted film. A breath of light from the top, a breath of shade at the
    // bottom.
    canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: dark ? 0.05 : 0.30),
              Colors.white.withValues(alpha: 0.0),
              Colors.black.withValues(alpha: dark ? 0.10 : 0.04),
            ],
            stops: const [0.0, 0.4, 1.0],
          ).createShader(rect));

    // The rim, twice: a crisp thread of highlight on the outer edge where the pane's
    // top-left catches the room, and a darker line just inside it where the edge
    // turns down into the glass — two lines a pixel apart are an edge with thickness.
    canvas.drawRRect(
        rr.deflate(0.75),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..shader = LinearGradient(
            begin: const Alignment(-0.8, -1),
            end: const Alignment(0.8, 1),
            colors: [
              Colors.white.withValues(alpha: dark ? 0.62 : 0.95),
              Colors.white.withValues(alpha: dark ? 0.10 : 0.35),
              Colors.white.withValues(alpha: dark ? 0.28 : 0.65),
            ],
          ).createShader(rect));
    canvas.drawRRect(
        rr.deflate(2.4),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.black.withValues(alpha: dark ? 0.30 : 0.10));
    // The lit band along the thickness, top-left, over the lens.
    final band = (size.shortestSide * 0.10).clamp(7.0, 16.0);
    canvas.drawRRect(
        rr.deflate(band / 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = band
          ..shader = LinearGradient(
            begin: const Alignment(-1, -1),
            end: const Alignment(1, 1),
            colors: [
              Colors.white.withValues(alpha: dark ? 0.14 : 0.35),
              Colors.white.withValues(alpha: 0.0),
              Colors.white.withValues(alpha: dark ? 0.06 : 0.18),
            ],
            stops: const [0.0, 0.55, 1.0],
          ).createShader(rect));

    // The room's light on the glass: each beam's reflection. A pane parallel to the
    // page shows a lamp's image some way behind it, so the image moves as the lamp
    // moves but by less — parallax — and a pane's fine polish stretches it across.
    // Tight and bright, not a wash: what moves is a streak, and the eye follows it.
    if (r != null && r.life > 0 && b != null) {
      final blend = r.onPaper ? BlendMode.srcOver : BlendMode.plus;
      final centre = rect.center;
      for (final (i, h) in r.heads.indexed) {
        final lamp = b.globalToLocal(h.at);
        final at = centre + (lamp - centre) * 0.62;
        final colour = r.colours.length > i ? r.colours[i] : Colors.white;
        final a = r.life * h.level;
        canvas.save();
        canvas.translate(at.dx, at.dy);
        canvas.rotate(h.lean * 0.6);
        final long = size.width * 0.34, tall = size.height * 0.26;
        canvas.drawOval(
            Rect.fromCenter(center: Offset.zero, width: long, height: tall),
            Paint()
              ..blendMode = blend
              ..shader = ui.Gradient.radial(
                Offset.zero,
                long / 2,
                [
                  Color.lerp(colour, Colors.white, 0.75)!.withValues(alpha: (r.onPaper ? 0.42 : 0.26) * a),
                  colour.withValues(alpha: (r.onPaper ? 0.14 : 0.08) * a),
                  colour.withValues(alpha: 0),
                ],
                const [0.0, 0.4, 1.0],
                TileMode.clamp,
                (Matrix4.identity()..scaleByDouble(1.0, tall / long, 1.0, 1.0)).storage,
              )
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, tall * 0.18));
        // The lamp itself, in the glass: a small hot streak.
        canvas.drawOval(
            Rect.fromCenter(center: Offset.zero, width: long * 0.36, height: tall * 0.16),
            Paint()
              ..blendMode = blend
              ..color = Colors.white.withValues(alpha: (r.onPaper ? 0.55 : 0.40) * a)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, tall * 0.08));
        canvas.restore();
        // The edge nearest the lamp, lit through its thickness.
        canvas.drawRRect(
            rr.deflate(1.0),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.0
              ..blendMode = blend
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.0)
              ..shader = RadialGradient(colors: [
                Colors.white.withValues(alpha: (r.onPaper ? 0.9 : 0.8) * a),
                Colors.white.withValues(alpha: 0),
              ]).createShader(Rect.fromCircle(center: lamp, radius: size.longestSide * 0.9)));
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
