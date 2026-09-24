import 'package:flutter/material.dart';

import '../../../api/models.dart';
import '../../../state/booth/booth.dart';
import 'console.dart';

/// What the house has on a record, as four small marks: its parts (the stems), the
/// tracker's beats, its sections read off the stems, and its words. Lit where it is
/// there, faint where it is not; the tooltip says so in words.
class DataMarks extends StatelessWidget {
  const DataMarks({super.key, required this.booth, required this.track, this.timing, this.size = 6});
  final Booth booth;
  final Track track;

  /// What is known already, where the caller has it; else the store is peeked.
  final TrackTiming? timing;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tm = timing ?? booth.timing.peek(track.id);
    final s = tm?.structure;
    final vocals = booth.vocals.peek(track.id);
    final stems = s?.fromStems ?? false;
    final tracker = s?.sources['neural'] == true;
    final sections = s != null && s.sections.any((x) => x.label != 'on');
    final words = vocals != null && vocals.lyrics != null && vocals.lyrics != 'later';
    final known = tm != null;
    final marks = [
      (stems, 'stems', 'in parts on the house'),
      (tracker, 'beats', 'beats and bars by the tracker'),
      (sections, 'sections', 'sections, drops and breakdowns read off the stems'),
      (words, 'words', 'its words, timed'),
    ];
    final tip = !known
        ? 'Not analysed yet'
        : [for (final (on, name, what) in marks) '${on ? '●' : '○'} $name — ${on ? what : 'not yet'}'].join('\n');
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 500),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (on, _, _) in marks)
            Padding(
              padding: EdgeInsets.only(right: size * 0.5),
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: on ? Console.ink : Colors.transparent,
                  border: Border.all(color: on ? Console.ink : Console.faint, width: 1),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
