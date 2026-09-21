import 'package:flutter/material.dart';

import 'motion.dart';

/// The shape of what is coming, while it comes.
///
/// A spinner says "something is happening" and nothing else: the screen is blank, its
/// size is unknown, and when the rows arrive they arrive all at once and the eye has
/// to start again. A list whose shape is already on screen reads as fast even when it
/// is not, because the waiting happens inside a page that already exists rather than
/// in front of one that does not.
///
/// Worth saying what this is *not*: it is not a promise that the thing will be this
/// long, or that it will arrive at all. It is the outline of a row, repeated, and the
/// real rows replace it in place.
class Bone extends StatefulWidget {
  const Bone({
    super.key,
    this.width,
    this.height = 12,
    this.radius = 6,
    this.shape = BoxShape.rectangle,
  });

  final double? width;
  final double height;
  final double radius;
  final BoxShape shape;

  @override
  State<Bone> createState() => _BoneState();
}

class _BoneState extends State<Bone> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Breathing rather than a sweep of light across the screen: a shimmer is a second
    // animation competing with the one the app is already running, and on the web it
    // is a whole extra layer to composite for something nobody is looking at.
    //
    // And nothing at all where the phone has been asked for no animation.
    if (stillness(context)) {
      return _box(scheme, 0.5);
    }
    return AnimatedBuilder(
      animation: _breath,
      builder: (context, _) => _box(scheme, 0.35 + 0.30 * _breath.value),
    );
  }

  Widget _box(ColorScheme scheme, double strength) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.06 * (strength / 0.5)),
          borderRadius: widget.shape == BoxShape.rectangle
              ? BorderRadius.circular(widget.radius)
              : null,
          shape: widget.shape,
        ),
      );
}

/// A list of songs, before there are any: artwork, a title, a line under it.
class SongsComing extends StatelessWidget {
  const SongsComing({super.key, this.rows = 8, this.padding});

  final int rows;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) => ListView.builder(
        padding: padding ?? const EdgeInsets.fromLTRB(8, 8, 8, 8),
        itemCount: rows,
        // Nothing here can be tapped or scrolled *to*; it is a picture of a list.
        physics: const NeverScrollableScrollPhysics(),
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
          child: Row(
            children: [
              const Bone(width: 44, height: 44, radius: 6),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Different widths down the list: a column of identical bars reads
                    // as a loading graphic, and rows of text do not all end together.
                    Bone(width: 120 + (i % 4) * 46),
                    const SizedBox(height: 8),
                    Bone(width: 80 + (i % 3) * 38, height: 10),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

/// People, before they arrive: a face, a name, a line about what they are playing.
class PeopleComing extends StatelessWidget {
  const PeopleComing({super.key, this.rows = 5});

  final int rows;

  @override
  Widget build(BuildContext context) => ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        itemCount: rows,
        physics: const NeverScrollableScrollPhysics(),
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: Row(
            children: [
              const Bone(width: 40, height: 40, shape: BoxShape.circle),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Bone(width: 90 + (i % 3) * 34),
                    const SizedBox(height: 8),
                    Bone(width: 140 + (i % 4) * 30, height: 10),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

/// A wall of records, before there are any.
class RecordsComing extends StatelessWidget {
  const RecordsComing({super.key, this.tiles = 12, this.extent = 190});

  final int tiles;
  final double extent;

  @override
  Widget build(BuildContext context) => GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: extent,
          childAspectRatio: 0.74,
          crossAxisSpacing: 12,
          mainAxisSpacing: 16,
        ),
        itemCount: tiles,
        itemBuilder: (context, i) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Expanded(child: Bone(height: double.infinity, radius: 10)),
            const SizedBox(height: 8),
            Bone(width: 90 + (i % 3) * 30),
            const SizedBox(height: 6),
            Bone(width: 60 + (i % 2) * 24, height: 10),
          ],
        ),
      );
}
