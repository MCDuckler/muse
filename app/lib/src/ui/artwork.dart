import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';

/// Album art with a placeholder that is deliberately not a grey box: a track with no
/// cover yet should still look like part of the app rather than a hole in it.
class Artwork extends StatelessWidget {
  const Artwork({
    super.key,
    required this.track,
    this.size = 44,
    this.radius = 6,
    this.small = true,
  });

  final Track? track;
  final double size;
  final double radius;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = track == null
        ? null
        : context.read<AppState>().api.coverUrl(track!, small: small);

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: url == null
            ? _placeholder(scheme)
            : Image.network(
                url,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => _placeholder(scheme),
                frameBuilder: (context, child, frame, wasSync) => wasSync || frame != null
                    ? child
                    : _placeholder(scheme),
              ),
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.surfaceContainerHighest, scheme.surfaceContainer],
          ),
        ),
        child: Icon(Icons.music_note,
            size: size * 0.5, color: scheme.primary.withValues(alpha: 0.5)),
      );
}
