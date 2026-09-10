import 'package:flutter/material.dart';

import '../api/models.dart';

/// Where a recording came from, as one small dot.
///
/// The library is fed from several places and they are not interchangeable: a Bandcamp
/// purchase is a proper file, a SoundCloud rip is whatever the artist uploaded, YouTube
/// is a transcode of a transcode, and something added by hand is whatever you put
/// there. That difference is worth seeing at a glance in a list of four hundred songs —
/// and only at a glance, which is why it is a dot rather than a word.
class SourceDot extends StatelessWidget {
  const SourceDot({super.key, required this.source, this.size = 7, this.ring});

  final String source;
  final double size;

  /// The colour behind the dot, so it reads as a mark *on* the artwork rather than a
  /// speck floating over it. Null for no ring.
  final Color? ring;

  /// Each source's own colour.
  ///
  /// SoundCloud orange and YouTube red were a few degrees of hue apart, which is fine
  /// on a brand sheet and useless at seven pixels across in a list: they read as the
  /// same dot. YouTube is pulled round to a cool red — nearly rose — so the two are
  /// telling apart at a glance rather than on inspection.
  static Color colourOf(String source, ColorScheme scheme) => switch (source) {
        'soundcloud' => const Color(0xFFFF7A00),
        'bandcamp' => const Color(0xFF1DA0C3),
        'youtube' => const Color(0xFFE11D48),
        // Anything put there by hand belongs to the person, not to a service.
        'custom' => scheme.primary,
        _ => scheme.outline,
      };

  static String labelOf(String source) => switch (source) {
        'soundcloud' => 'SoundCloud',
        'bandcamp' => 'Bandcamp',
        'youtube' => 'YouTube',
        'custom' => 'Your upload',
        _ => 'Unknown source',
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ringWidth = ring == null ? 0.0 : 1.5;
    return Tooltip(
      message: labelOf(source),
      waitDuration: const Duration(milliseconds: 600),
      child: Container(
        width: size + ringWidth * 2,
        height: size + ringWidth * 2,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: ring ?? Colors.transparent,
        ),
        child: Center(
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colourOf(source, scheme),
            ),
          ),
        ),
      ),
    );
  }
}

/// Artwork with the source marked in its corner. The dot sits *on* the picture rather
/// than beside it, so a row is no taller and no wider for having one.
class MarkedArtwork extends StatelessWidget {
  const MarkedArtwork({
    super.key,
    required this.child,
    required this.source,
    this.dotSize = 7,
  });

  final Widget child;
  final String source;
  final double dotSize;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          right: -2,
          bottom: -2,
          child: SourceDot(
            source: source,
            size: dotSize,
            ring: Theme.of(context).colorScheme.surface,
          ),
        ),
      ],
    );
  }
}

/// The same mark, said in words. For the places with room for a line of text.
class SourceChip extends StatelessWidget {
  const SourceChip({super.key, required this.track});
  final Track track;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SourceDot(source: track.source),
        const SizedBox(width: 6),
        Text(SourceDot.labelOf(track.source),
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant)),
      ],
    );
  }
}
