// Keeping what is on the stage as a favourite (state/show/show_faves.dart): the
// combination and the rest of it from the engine, and a small picture of the stage
// as it is from whichever surface shows it — the booth's picture, or the stage page
// over the window (a stage in a window of its own sends its picture back to the
// booth's, so that one is it).
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../state/show/show_engine.dart';
import '../../state/show/show_faves.dart';
import 'fave_thumbs_none.dart' if (dart.library.io) 'fave_thumbs_io.dart';

export 'fave_thumbs_none.dart' if (dart.library.io) 'fave_thumbs_io.dart';

/// The surfaces showing the stage, the newest (the one on top) first to be asked.
class StageGrabs {
  const StageGrabs._();
  static final _grabs = <GlobalKey>[];

  /// How wide a favourite's picture is.
  static const width = 320.0;

  /// The stage as it is now, [width] wide; null where nothing shows it.
  static Future<ui.Image?> grab() async {
    for (final key in _grabs.reversed) {
      final b = key.currentContext?.findRenderObject();
      if (b is! RenderRepaintBoundary || b.size.isEmpty || !b.attached) continue;
      try {
        return await b.toImage(pixelRatio: width / b.size.width);
      } catch (_) {}
    }
    return null;
  }
}

/// A surface showing the stage, for [StageGrabs].
class GrabbableStage extends StatefulWidget {
  const GrabbableStage({super.key, required this.child});
  final Widget child;

  @override
  State<GrabbableStage> createState() => _GrabbableStageState();
}

class _GrabbableStageState extends State<GrabbableStage> {
  final _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    StageGrabs._grabs.add(_key);
  }

  @override
  void dispose() {
    StageGrabs._grabs.remove(_key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(key: _key, child: widget.child);
}

/// What is on the stage kept as a favourite, with its picture: null while nothing
/// is on.
Future<ShowFave?> keepFaveNow(ShowEngine show) async {
  final f = show.faveNow();
  if (f == null) return null;
  // The picture first (the moment the hands asked for), kept before the list says it.
  final image = await StageGrabs.grab();
  if (image != null) {
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data != null) await FaveThumbs.keep(f.id, Uint8List.sublistView(data));
    } finally {
      image.dispose();
    }
  }
  show.keepFave(f);
  return f;
}
