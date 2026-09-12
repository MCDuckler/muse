import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

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
  });

  final Widget child;
  final double blur;
  final double opacity;
  final BorderRadius? borderRadius;
  final bool topBorder;
  final EdgeInsetsGeometry padding;

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

    return ClipRRect(
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
        ],
      ),
    );
  }
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
