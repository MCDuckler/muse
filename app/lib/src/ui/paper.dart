import 'package:flutter/material.dart';

/// The paper the whole app is printed on.
///
/// A magazine is ink on stock, and stock has a tooth: a faint, uneven grain that a
/// flat colour on a screen does not. This lays that grain over everything — one small
/// texture, tiled, at one texel per device pixel so it reads as paper rather than as a
/// pattern — with dark specks that show on a light edition and light ones that show on
/// the late edition, both in the same file.
///
/// Over everything rather than under it, because under it would mean every page's
/// background going transparent, and a page that is transparent shows the page behind
/// it for the length of every transition. At the strength it is drawn, the covers it
/// passes over do not notice.
///
/// Its own layer, drawn once: nothing about it changes while the app runs, so it costs
/// a composite, not a repaint.
class PaperGrain extends StatelessWidget {
  const PaperGrain({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: RepaintBoundary(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    image: DecorationImage(
                      image: const AssetImage('assets/texture/grain.png'),
                      repeat: ImageRepeat.repeat,
                      // One texel to one device pixel.
                      scale: ratio,
                      opacity: dark ? 0.5 : 0.75,
                      filterQuality: FilterQuality.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
