// What a stage needs before it can draw: the scene files and the shader programs,
// loaded once per process and shared by the preview tile, the stage page and the
// stage window.
import 'dart:async';

import 'package:flutter/services.dart';

import '../../state/show/combo_scores.dart';

import 'scene.dart';
import 'show_canvas.dart';
import 'show_sims.dart';

class StageKit {
  const StageKit(this.book, this.programs);
  final SceneBook book;
  final StagePrograms programs;

  static StageKit? _kit;
  static Future<StageKit>? _loading;

  /// Read once; the kit itself is kept, not the future that read it — a future
  /// completed in one test's zone would never deliver to the next test's await.
  static Future<StageKit> load() {
    final kit = _kit;
    if (kit != null) return Future.value(kit);
    return _loading ??= () async {
      final book = await SceneBook.load();
      await ComboScores.load(rootBundle);
      for (final s in book.scenes.values) {
        for (final l in s.layers) {
          if (l.sim != null) SimLayer.warm(l.sim!);
        }
      }
      final programs = await StagePrograms.load(book);
      return _kit = StageKit(book, programs);
    }();
  }
}
