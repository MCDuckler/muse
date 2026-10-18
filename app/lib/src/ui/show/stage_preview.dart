// The booth's picture of the show: the stage drawn here (StageSurface) — or, while
// a stage in a window of its own has the show, the picture that window sends back,
// so the booth draws nothing twice (no second MilkDrop, no second set of dancers).
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../state/booth/board/link_server.dart';
import '../../state/show/show_feed.dart';
import 'native_stage.dart';
import 'scene.dart';
import 'show_canvas.dart';
import 'show_debug.dart';

class StagePreview extends StatelessWidget {
  const StagePreview({super.key, required this.feed, required this.book, required this.programs, this.scale = 0.4, this.rank = 0, this.info});
  final ShowFeed feed;
  final SceneBook book;
  final StagePrograms programs;
  final double scale;
  final int rank;
  final ValueNotifier<StageInfo>? info;

  @override
  Widget build(BuildContext context) {
    final link = context.read<AppState?>()?.boardLink;
    if (link == null) return _own(context);
    return ValueListenableBuilder<StageThumb?>(
      valueListenable: link.stageThumb,
      builder: (context, thumb, _) => thumb == null ? _own(context) : _ThumbView(thumbs: link.stageThumb, info: info),
    );
  }

  Widget _own(BuildContext context) => StageSurface(
        feed: feed,
        book: book,
        programs: programs,
        scale: scale,
        preview: true,
        rank: rank,
        info: info,
        slow: () => (context.read<AppState?>()?.boardLink?.stages ?? 0) > 0,
      );
}

/// The window's picture, decoded as it comes.
class _ThumbView extends StatefulWidget {
  const _ThumbView({required this.thumbs, this.info});
  final ValueNotifier<StageThumb?> thumbs;
  final ValueNotifier<StageInfo>? info;

  @override
  State<_ThumbView> createState() => _ThumbViewState();
}

class _ThumbViewState extends State<_ThumbView> {
  ui.Image? _image;
  bool _decoding = false;
  int _got = 0;
  DateTime _rateAt = DateTime.now();
  double _fps = 0;

  @override
  void initState() {
    super.initState();
    widget.thumbs.addListener(_came);
    // Noted after the frame: a note during a build would mark its readers mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ShowDebug.note('the booth\'s picture: the window\'s own, sent back (nothing drawn here)');
    });
    _came();
  }

  @override
  void dispose() {
    widget.thumbs.removeListener(_came);
    _image?.dispose();
    super.dispose();
  }

  void _came() {
    final t = widget.thumbs.value;
    if (t == null || _decoding) return;
    _decoding = true;
    ui.decodeImageFromPixels(t.rgba, t.width, t.height, ui.PixelFormat.rgba8888, (img) {
      _decoding = false;
      if (!mounted) {
        img.dispose();
        return;
      }
      _image?.dispose();
      _got++;
      final now = DateTime.now();
      final dt = now.difference(_rateAt).inMilliseconds;
      if (dt >= 1000) {
        _fps = _got * 1000 / dt;
        _got = 0;
        _rateAt = now;
        widget.info?.value = StageInfo(native: false, why: 'the stage in its own window draws; this is its picture', fps: _fps, width: t.width, height: t.height);
      }
      setState(() => _image = img);
    });
  }

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
        const ColoredBox(color: Colors.black),
        if (_image != null) RawImage(image: _image, fit: BoxFit.cover, filterQuality: FilterQuality.low),
        Positioned(
          right: 6,
          bottom: 4,
          child: Text('from the window', style: TextStyle(fontSize: 10, color: Colors.white.withValues(alpha: 0.6))),
        ),
      ]);
}
