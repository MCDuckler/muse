// MilkDrop's own picture, as the helper draws it: for the browser and the maker,
// where the show's post over it would get in the way of judging a preset.
import 'package:flutter/material.dart';

import '../../state/show/milk_feed.dart';
import '../booth/desk/console.dart';

class MilkPreview extends StatelessWidget {
  const MilkPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final feed = MilkFeed.shared;
    return ListenableBuilder(
      listenable: feed,
      builder: (context, _) => AspectRatio(
        aspectRatio: MilkFeed.width / MilkFeed.height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ColoredBox(
            color: Colors.black,
            child: feed.frame == null
                ? Center(
                    child: Text(
                      feed.trouble ?? (feed.running ? 'MilkDrop is starting…' : 'MilkDrop is off'),
                      style: TextStyle(color: Console.quiet, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  )
                : CustomPaint(painter: _FramePainter(feed), child: const SizedBox.expand()),
          ),
        ),
      ),
    );
  }
}

class _FramePainter extends CustomPainter {
  _FramePainter(this.feed) : super(repaint: feed);
  final MilkFeed feed;

  @override
  void paint(Canvas canvas, Size size) {
    final img = feed.frame;
    if (img == null) return;
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) => true;
}
