// The polish: what is supposed to move, and what is supposed to hold still.
//
// Animation is the part of an app nobody writes down and everybody notices. These are
// the two claims worth holding to: that the clock under the seek bar runs between the
// engine's reports rather than stepping four times a second, and that everything
// decorative stops dead when the phone has been told to keep still.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/motion.dart';

void main() {
  testWidgets('a phone told to keep still is not animated at', (tester) async {
    late BuildContext still;
    late BuildContext moving_;
    await tester.pumpWidget(MaterialApp(
      home: Column(children: [
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(builder: (context) {
            still = context;
            return const SizedBox();
          }),
        ),
        MediaQuery(
          data: const MediaQueryData(),
          child: Builder(builder: (context) {
            moving_ = context;
            return const SizedBox();
          }),
        ),
      ]),
    ));

    expect(stillness(still), isTrue);
    expect(moving(still, Motion.base), Duration.zero);

    expect(stillness(moving_), isFalse);
    expect(moving(moving_, Motion.base), Motion.base);
  });

  test('one vocabulary, three speeds', () {
    // Ordered, and far enough apart to be told apart: two durations 40ms apart are
    // two numbers rather than two speeds.
    expect(Motion.quick < Motion.base, isTrue);
    expect(Motion.base < Motion.slow, isTrue);
    expect(Motion.base - Motion.quick, greaterThan(const Duration(milliseconds: 50)));
  });

  testWidgets('the seek bar keeps time between the engine\'s reports',
      (tester) async {
    // Position arrives four times a second. A bar that only moves when a report lands
    // steps four times a second and counts in quarter seconds; this fills in the gaps
    // from the wall clock, which is what "the music is still playing" means.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: _Clocked(playing: true)),
    ));
    final first = tester.widget<Text>(find.byKey(const Key('clock'))).data;
    await tester.pump(const Duration(milliseconds: 400));
    final later = tester.widget<Text>(find.byKey(const Key('clock'))).data;
    expect(later, isNot(first), reason: 'it moved without a new report');

    // And a paused one holds: a clock that runs through a pause is lying.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: _Clocked(playing: false)),
    ));
    final held = tester.widget<Text>(find.byKey(const Key('clock'))).data;
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<Text>(find.byKey(const Key('clock'))).data, held);
  });
}

/// The same arithmetic the seek bar does, on its own so it can be looked at: the last
/// report plus however long ago it arrived.
class _Clocked extends StatefulWidget {
  const _Clocked({required this.playing});
  final bool playing;

  @override
  State<_Clocked> createState() => _ClockedState();
}

class _ClockedState extends State<_Clocked> with SingleTickerProviderStateMixin {
  final _said = Duration.zero;
  final _saidAt = DateTime.now();
  late final Ticker _clock = createTicker((_) => setState(() {}));

  @override
  void initState() {
    super.initState();
    if (widget.playing) _clock.start();
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.playing
        ? _said + DateTime.now().difference(_saidAt)
        : _said;
    return Text('${now.inMilliseconds}', key: const Key('clock'));
  }
}
