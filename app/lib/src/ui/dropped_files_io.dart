import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Dropping music onto the window, in the desktop app.
///
/// The same gesture the browser build has, for the same reason: on a desk the file is
/// already in a window next to this one. A phone has no desktop to drag from, so there
/// it is the app carrying on being the app.
class DropToAdd extends StatefulWidget {
  const DropToAdd({super.key, required this.child, required this.onFiles});

  final Widget child;
  final Future<void> Function(List<({String name, List<int> bytes})>) onFiles;

  @override
  State<DropToAdd> createState() => _DropToAddState();
}

class _DropToAddState extends State<DropToAdd> {
  bool _over = false;

  static bool get _onADesk =>
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS;

  /// What a music file is called. A folder dragged in by mistake, or a spreadsheet, is
  /// not uploaded to find out that it is not a song.
  static const _audio = {
    'mp3', 'm4a', 'aac', 'flac', 'wav', 'ogg', 'opus', 'wma', 'aiff', 'aif', 'alac', 'webm',
  };

  Future<void> _dropped(DropDoneDetails details) async {
    setState(() => _over = false);
    final got = <({String name, List<int> bytes})>[];
    for (final item in details.files) {
      final name = item.name;
      final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
      if (!_audio.contains(ext)) continue;
      try {
        if (await FileSystemEntity.isDirectory(item.path)) continue;
        got.add((name: name, bytes: await File(item.path).readAsBytes()));
      } catch (_) {
        // Gone, or not ours to read: the others still go.
      }
    }
    if (got.isNotEmpty) await widget.onFiles(got);
  }

  @override
  Widget build(BuildContext context) {
    if (!_onADesk) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => setState(() => _over = true),
      onDragExited: (_) => setState(() => _over = false),
      onDragDone: _dropped,
      child: Stack(
        children: [
          widget.child,
          // Only while something is held over the window, and never in a pointer's way.
          if (_over)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: scheme.primary.withValues(alpha: 0.10),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        border: Border.all(color: scheme.onSurface, width: 2),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.library_music_outlined, size: 36, color: scheme.primary),
                          const SizedBox(height: 10),
                          Text('Drop it here to add it to your library',
                              style: Theme.of(context).textTheme.titleMedium),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
