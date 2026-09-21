import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// Dropping music onto the window.
///
/// Adding a file the downloader cannot fetch — a bootleg, a friend's mix, something
/// ripped from a CD — meant finding it in Settings, under "Your music", behind a file
/// picker. On a desk the file is already in a window next to this one, and the gesture
/// everybody tries first is to drag it in. The browser refuses by default: it takes
/// the drop as "open this file instead of the page" and navigates away from the app,
/// which is worse than nothing.
///
/// So the page says it will take them, catches them, and hands them up.
class DropToAdd extends StatefulWidget {
  const DropToAdd({super.key, required this.child, required this.onFiles});

  final Widget child;

  /// What was dropped, already read: the web has no paths, only bytes.
  final Future<void> Function(List<({String name, List<int> bytes})>) onFiles;

  @override
  State<DropToAdd> createState() => _DropToAddState();
}

class _DropToAddState extends State<DropToAdd> {
  bool _over = false;
  int _depth = 0;                // enter/leave fire for every child element

  late final JSFunction _onOver;
  late final JSFunction _onEnter;
  late final JSFunction _onLeave;
  late final JSFunction _onDrop;

  @override
  void initState() {
    super.initState();
    _onOver = ((web.DragEvent e) => e.preventDefault()).toJS;
    _onEnter = ((web.DragEvent e) {
      e.preventDefault();
      _depth++;
      if (!_over) setState(() => _over = true);
    }).toJS;
    _onLeave = ((web.DragEvent e) {
      e.preventDefault();
      _depth--;
      if (_depth <= 0 && _over) setState(() => _over = false);
    }).toJS;
    _onDrop = ((web.DragEvent e) {
      e.preventDefault();
      _depth = 0;
      setState(() => _over = false);
      unawaited(_take(e));
    }).toJS;

    web.document.addEventListener('dragover', _onOver);
    web.document.addEventListener('dragenter', _onEnter);
    web.document.addEventListener('dragleave', _onLeave);
    web.document.addEventListener('drop', _onDrop);
  }

  @override
  void dispose() {
    web.document.removeEventListener('dragover', _onOver);
    web.document.removeEventListener('dragenter', _onEnter);
    web.document.removeEventListener('dragleave', _onLeave);
    web.document.removeEventListener('drop', _onDrop);
    super.dispose();
  }

  Future<void> _take(web.DragEvent event) async {
    final files = event.dataTransfer?.files;
    if (files == null || files.length == 0) return;
    final got = <({String name, List<int> bytes})>[];
    for (var i = 0; i < files.length; i++) {
      final file = files.item(i);
      if (file == null) continue;
      final buffer = await file.arrayBuffer().toDart;
      got.add((name: file.name, bytes: buffer.toDart.asUint8List()));
    }
    if (got.isNotEmpty) await widget.onFiles(got);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        widget.child,
        // Only while something is being held over the window, and never in the way of
        // a pointer: what is underneath is still the app.
        if (_over)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: scheme.primary.withValues(alpha: 0.10),
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 22),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.library_music_outlined,
                              size: 36, color: scheme.primary),
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
          ),
      ],
    );
  }
}
