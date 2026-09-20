import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/art_cache.dart';

/// Somebody, as a picture or as the first letter of their name.
///
/// Used wherever a person appears rather than a song: the account in settings, who is
/// in a jam, who to invite. A name with a face on it is how you tell at a glance which
/// of the two Chrises is listening.
class Face extends StatelessWidget {
  const Face({
    super.key,
    required this.name,
    this.userId,
    this.version,
    this.size = 40,
  });

  final String? name;
  final int? userId;

  /// The version of their picture. Null means they have not chosen one.
  final String? version;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = ((name ?? '?').trim().isEmpty ? '?' : name!.trim())
        .characters
        .first
        .toUpperCase();
    final letter = CircleAvatar(
      radius: size / 2,
      backgroundColor: scheme.surfaceContainerHighest,
      child: Text(initial, style: TextStyle(fontSize: size * 0.4)),
    );
    if (version == null || userId == null) return letter;
    return ClipOval(
      child: Image(
        image: artwork(
            context.read<AppState>().api.avatarUrl(userId!, version: version),
            drawnAt: size,
            ratio: MediaQuery.devicePixelRatioOf(context)),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, _, __) => letter,
      ),
    );
  }
}
