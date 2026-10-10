// The stage over the whole window, in this process: for one screen mirrored to a
// television, or a look at the show as the room will see it. Esc comes back.
//
// Keys: ← → the scene · H hit · B blackout · S strobe (held) · F freeze · Esc back.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/booth/booth.dart';
import '../../state/show/show_feed.dart';
import '../../state/show/show_state.dart';
import 'show_canvas.dart';
import 'stage_kit.dart';

Future<void> openStagePage(BuildContext context, Booth booth) => Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (context, _, __) => StagePage(feed: booth.show, onKey: StageHands.ofEngine(booth)),
        transitionsBuilder: (context, a, _, child) => FadeTransition(opacity: a, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );

/// The performer's hands on a stage, by key — on the engine, or on a demo feed.
class StageHands {
  const StageHands({required this.next, required this.previous, required this.hit, required this.macros, required this.setMacros});
  final VoidCallback next, previous, hit;
  final ShowMacros Function() macros;
  final void Function(ShowMacros) setMacros;

  static StageHands ofEngine(Booth booth) => StageHands(
        next: booth.show.nextScene,
        previous: booth.show.previousScene,
        hit: booth.show.hit,
        macros: () => booth.show.macros,
        setMacros: booth.show.setMacros,
      );

  static const none = StageHands(next: _nothing, previous: _nothing, hit: _nothing, macros: _noMacros, setMacros: _setNothing);
  static void _nothing() {}
  static ShowMacros _noMacros() => ShowMacros.none;
  static void _setNothing(ShowMacros _) {}

  /// A key, down or up: true when it was the stage's.
  bool key(KeyEvent e) {
    final k = e.logicalKey;
    if (e is KeyUpEvent) {
      if (k == LogicalKeyboardKey.keyS) {
        setMacros(macros().copyWith(strobe: 0));
        return true;
      }
      return false;
    }
    if (e is! KeyDownEvent) return false;
    if (k == LogicalKeyboardKey.arrowRight) {
      next();
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      previous();
    } else if (k == LogicalKeyboardKey.keyH || k == LogicalKeyboardKey.space) {
      hit();
    } else if (k == LogicalKeyboardKey.keyB) {
      setMacros(macros().copyWith(blackout: !macros().blackout));
    } else if (k == LogicalKeyboardKey.keyF) {
      setMacros(macros().copyWith(freeze: !macros().freeze));
    } else if (k == LogicalKeyboardKey.keyS) {
      setMacros(macros().copyWith(strobe: 1));
    } else {
      return false;
    }
    return true;
  }
}

class StagePage extends StatefulWidget {
  const StagePage({super.key, required this.feed, this.onKey = StageHands.none, this.scale = 0.75, this.canPop = true});
  final ShowFeed feed;
  final StageHands onKey;
  final double scale;
  final bool canPop;

  @override
  State<StagePage> createState() => _StagePageState();
}

class _StagePageState extends State<StagePage> {
  StageKit? _kit;
  String? _trouble;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    unawaited(StageKit.load().then((k) {
      if (mounted) setState(() => _kit = k);
    }, onError: (Object e) {
      if (mounted) setState(() => _trouble = '$e');
    }));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _keys(FocusNode node, KeyEvent e) {
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape && widget.canPop) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return widget.onKey.key(e) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final kit = _kit;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _keys,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _trouble != null
            ? Center(child: Text('The stage could not load its shaders.\n$_trouble'))
            : kit == null
                ? const SizedBox.shrink()
                : ShowCanvas(feed: widget.feed, book: kit.book, programs: kit.programs, scale: widget.scale),
      ),
    );
  }
}
