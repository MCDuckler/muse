// The show's debug words: which stage draws a surface (the native one, or Flutter's),
// why, how fast — over the picture while the switch is on (the bug pad in the booth's
// show tile, the I key on the stage page), and the last few times a surface changed
// hands between the two, so a stage that fell back to Flutter says when and why.
//
// Kept in the preferences (muse.show.debug): on for the performer who is hunting a
// slow evening until they turn it off.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'native_stage.dart' show StageInfo;

class ShowDebug {
  const ShowDebug._();

  /// The words shown over every stage surface.
  static final on = ValueNotifier<bool>(false);

  static const _k = 'muse.show.debug';
  static Future<void>? _loading;
  static bool _loaded = false;

  /// Read once from the preferences (any surface asks; the first ask reads).
  static Future<void> load() {
    if (_loaded) return Future.value();
    return _loading ??= () async {
      try {
        final p = await SharedPreferences.getInstance();
        on.value = p.getBool(_k) ?? false;
      } catch (_) {}
      _loaded = true;
    }();
  }

  static Future<void> set(bool v) async {
    on.value = v;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_k, v);
    } catch (_) {}
  }

  static void toggle() => unawaited(set(!on.value));

  /// The last few times a surface changed hands between the renderers, or a stage
  /// was given up or tried again — newest last, each with its time.
  static final flips = ValueNotifier<List<String>>(const []);

  static void note(String what) {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final line = '${two(t.hour)}:${two(t.minute)}:${two(t.second)} $what';
    debugPrint('stage: $what');
    final was = flips.value;
    flips.value = [...was.skip(was.length > 7 ? was.length - 7 : 0), line];
  }
}

/// The debug words over a stage surface: [info] as the surface last said it, asked
/// again four times a second for the numbers that move.
class StageDebugWords extends StatefulWidget {
  const StageDebugWords({super.key, required this.info, this.refresh});
  final ValueListenable<StageInfo> info;

  /// Asked on each tick for the latest numbers (a native stage's fps); null uses
  /// [info] as it is.
  final StageInfo Function()? refresh;

  @override
  State<StageDebugWords> createState() => _StageDebugWordsState();
}

class _StageDebugWordsState extends State<StageDebugWords> {
  Timer? _tick;
  StageInfo? _fresh;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final r = widget.refresh;
      if (r == null) return;
      final i = r();
      if (mounted) setState(() => _fresh = i);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<StageInfo>(
        valueListenable: widget.info,
        builder: (context, said, _) => ValueListenableBuilder<List<String>>(
          valueListenable: ShowDebug.flips,
          builder: (context, flips, _) {
            final i = _fresh ?? said;
            final lines = <String>[
              '${i.native ? 'NATIVE' : 'FLUTTER'}${i.parked ? ' (parked)' : ''} · ${i.fps.toStringAsFixed(i.fps >= 10 ? 0 : 1)} fps'
                  '${i.native ? ' · ${i.ms.toStringAsFixed(1)} ms, worst ${i.worstMs.toStringAsFixed(1)}' : ''}'
                  '${i.width > 0 ? ' · ${i.width}×${i.height}' : ''}'
                  '${i.native && i.workWidth > 0 ? ' → ${i.workWidth}×${i.workHeight} (auto ×${i.autoScale.toStringAsFixed(2)})' : ''}'
                  '${!i.native && i.scale != 1 ? ' · scale ${i.scale.toStringAsFixed(2)}' : ''}'
                  '${i.native ? (i.float ? ' · float' : ' · 8-bit') : ''}'
                  '${i.scene != null ? ' · ${i.scene}' : ''}',
              if (i.why.isNotEmpty) 'why not native: ${i.why}',
              ...flips.skip(flips.length > 4 ? flips.length - 4 : 0),
            ];
            return IgnorePointer(
              child: Align(
                alignment: Alignment.topLeft,
                child: Container(
                  margin: const EdgeInsets.all(6),
                  padding: const EdgeInsets.fromLTRB(7, 4, 8, 5),
                  decoration: BoxDecoration(color: const Color(0xa0000000), borderRadius: BorderRadius.circular(4)),
                  child: Text(
                    lines.join('\n'),
                    style: const TextStyle(fontFamily: 'CourierPrime', fontSize: 11, height: 1.25, color: Color(0xffe8e8e8)),
                  ),
                ),
              ),
            );
          },
        ),
      );
}
