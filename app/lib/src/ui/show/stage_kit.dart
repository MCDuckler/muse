// What a stage needs before it can draw: the scene files and the shader programs,
// loaded once per process and shared by the preview tile, the stage page and the
// stage window.
import 'dart:async';

import 'scene.dart';
import 'show_canvas.dart';

class StageKit {
  const StageKit(this.book, this.programs);
  final SceneBook book;
  final StagePrograms programs;

  static Future<StageKit>? _loading;

  static Future<StageKit> load() => _loading ??= () async {
        final book = await SceneBook.load();
        final programs = await StagePrograms.load(book);
        return StageKit(book, programs);
      }();
}
