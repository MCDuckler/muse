// Does skipping actually change what is coming out of the speakers?
//
// The player screen can look right while the audio engine is still holding the
// previous track, which is exactly the complaint. So this asserts on what the engine
// reports — the loaded track and the duration it thinks it has — rather than on labels.
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:muse/main.dart' as app;
import 'package:muse/src/api/models.dart';

@JS('eval')
external JSAny? _eval(String script);

/// just_audio creates its media elements detached from the document, so they cannot be
/// found by querying the DOM. Hooking the prototype is the only way to see what the
/// browser is actually being told to play.
void _watchTheAudioElement() {
  _eval(r"""
    window.__log = [];
    window.__n = 0;
    function tag(el) {
      if (!el.__id) { el.__id = ++window.__n; }
      return '#' + el.__id;
    }
    function short(v) { return String(v).replace(/\?.*/, '').replace(/^.*\/tracks\//, 't'); }

    var d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
    Object.defineProperty(HTMLMediaElement.prototype, 'src', {
      get: function() { window.__reads = (window.__reads || 0) + 1; return d.get.call(this); },
      set: function(v) { window.__log.push(tag(this) + ' src=' + short(v)); d.set.call(this, v); }
    });
    var setAttr = HTMLMediaElement.prototype.setAttribute;
    HTMLMediaElement.prototype.setAttribute = function(k, v) {
      if (k === 'src') window.__log.push(tag(this) + ' attr=' + short(v));
      return setAttr.apply(this, arguments);
    };
    var load = HTMLMediaElement.prototype.load;
    HTMLMediaElement.prototype.load = function() {
      window.__log.push(tag(this) + ' load ' + short(this.src));
      return load.apply(this, arguments);
    };
    var play = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function() {
      window.__log.push(tag(this) + ' play ' + short(this.src) + ' d=' + Math.round(this.duration));
      return play.apply(this, arguments);
    };
    var pause = HTMLMediaElement.prototype.pause;
    HTMLMediaElement.prototype.pause = function() {
      window.__log.push(tag(this) + ' pause ' + short(this.src));
      return pause.apply(this, arguments);
    };
    var RealAudio = window.Audio;
    window.Audio = function(src) {
      var el = src === undefined ? new RealAudio() : new RealAudio(src);
      window.__log.push(tag(el) + ' new Audio(' + (src === undefined ? '' : short(src)) + ')');
      return el;
    };
    window.Audio.prototype = RealAudio.prototype;
    var create = Document.prototype.createElement;
    Document.prototype.createElement = function(name) {
      var el = create.apply(this, arguments);
      if (String(name).toLowerCase() === 'audio') {
        window.__log.push(tag(el) + ' createElement(audio)');
      }
      return el;
    };
  """);
}

/// How many media elements the page has built. It has to stay at one: a browser gives
/// permission to make sound to an *element*, so a player that throws its element away
/// per track has to ask for a tap again every time — which is where "NotAllowedError:
/// The play method is not allowed" came from.
int _elementsBuilt() =>
    ((_eval('(window.__log || []).filter(function(l){return /createElement|new Audio/.test(l);}).length')
        as JSNumber?)?.toDartInt) ?? -1;

String _audioLog() =>
    (_eval('(window.__log || []).join(" ~ ") + " | src reads: " + (window.__reads||0)')
        as JSString?)?.toDart ?? '(none)';

/// Marks a phase in the element log, so what the app did lines up with what the
/// browser was told.
void _mark(String what) => _eval('window.__log.push("--- $what ---")');

const user = String.fromEnvironment('MUSE_USER', defaultValue: 'chris');
const pass = String.fromEnvironment('MUSE_PASS');

Future<void> settle(WidgetTester tester, {int seconds = 3}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    tester.takeException();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final scratchName = 'skip-${DateTime.now().millisecondsSinceEpoch}';
  int? scratchId;

  tearDownAll(() async {
    final api = app.debugAppState?.api;
    if (api != null && scratchId != null) await api.deleteQueue(scratchId!);
  });

  testWidgets('skipping loads the next song, not the one already playing',
      (tester) async {
    _watchTheAudioElement();
    app.main();
    await settle(tester, seconds: 4);

    // Sign in through the screen, the way the main test does.
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2), reason: 'login screen should be up');
    await tester.enterText(fields.at(0), user);
    await tester.enterText(fields.at(1), pass);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await settle(tester, seconds: 8);

    final state = app.debugAppState!;
    final api = state.api;

    // Three downloaded songs of different lengths, so the engine's own duration says
    // which one it is holding. The library listing has no stream url on it, so the
    // queue is read back afterwards for the playable rows.
    // Ask the server for playable rows: with a big mirror running, the newest few
    // hundred tracks in the library are all still downloading.
    final library = await api.libraryTracks(limit: 400, readyOnly: true);
    final picks = <Track>[];
    for (final t in library.items) {
      if (t.state != 'ready' || t.durationMs == null) continue;
      if (picks.any((c) => c.id == t.id)) continue;
      if (picks.any((c) => (c.durationMs! - t.durationMs!).abs() < 5000)) continue;
      picks.add(t);
      if (picks.length == 3) break;
    }
    expect(picks.length, 3, reason: 'need three downloaded tracks of different lengths');

    final queue = await api.createQueue(scratchName);
    scratchId = queue.id;
    await api.addToQueue(queue.id, picks.map((t) => t.id).toList());
    await state.openQueue(queue.id);
    await settle(tester, seconds: 3);

    final chosen = state.player!.items;
    expect(chosen.length, 3);
    expect(chosen.every((t) => t.isReady), isTrue,
        reason: 'the queue rows must be playable');

    final player = state.player!;
    _mark('playAt(0)');
    await player.playAt(0);
    await settle(tester, seconds: 6);

    final trace = <String>[];
    void note(String s) => trace.add(s);

    var snap = app.debugPlayerSnapshot()!;
    note('urls: ${chosen.map((t) => api.streamUrl(t).split('?').first).join(' ')}');
    note('start: current=${snap.current?.id} loaded=${snap.loadedTrackId} '
        'dur=${snap.duration?.inMilliseconds} want=${chosen[0].durationMs} '
        'pos=${snap.position.inMilliseconds} err=${snap.error}');
    await settle(tester, seconds: 3);
    final second = app.debugPlayerSnapshot()!;
    note('3s later: pos=${second.position.inMilliseconds} '
        'dur=${second.duration?.inMilliseconds}');
    expect(snap.playing, isTrue, reason: 'nothing to test if it never started. $trace');

    for (var i = 1; i < 3; i++) {
      _mark('next $i');
      await player.next();
      await settle(tester, seconds: 6);
      snap = app.debugPlayerSnapshot()!;
      note('after skip $i: current=${snap.current?.id} loaded=${snap.loadedTrackId} '
          'pos=${snap.position.inMilliseconds} dur=${snap.duration?.inMilliseconds} '
          'want=${chosen[i].id}/${chosen[i].durationMs} err=${snap.error} '
          'src=${player.lastSourceUrl}');

      // A seek past where the previous (shorter) file ends. If the engine were still
      // on that file it could not follow us there, and would drop to the next track.
      final deep = Duration(milliseconds: chosen[i].durationMs! - 20000);
      await player.seek(deep);
      await settle(tester, seconds: 4);
      final after = app.debugPlayerSnapshot()!;
      note('seek $i to ${deep.inSeconds}s -> pos=${after.position.inSeconds}s '
          'current=${after.current?.id}');
      expect(after.current?.id, chosen[i].id,
          reason: 'seeking deep into the song must stay in the song. $trace '
              '|| AUDIO: ${_audioLog()}');
      expect(after.position.inSeconds, greaterThan(deep.inSeconds - 5),
          reason: 'the engine must be on a file that long. $trace '
              '|| AUDIO: ${_audioLog()}');

      expect(snap.current?.id, chosen[i].id, reason: 'the screen must move on. $trace');
      expect(snap.loadedTrackId, chosen[i].id,
          reason: 'the engine must hold the song the screen is showing. $trace');
      // The engine's own idea of the file, which cannot be faked by the UI.
      final duration = snap.duration?.inMilliseconds ?? 0;
      expect((duration - chosen[i].durationMs!).abs() < 2000, isTrue,
          reason: 'the audio engine is still on a different file. $trace '
              '|| AUDIO: ${_audioLog()}');
      expect(snap.position.inSeconds, lessThan(6),
          reason: 'a skip starts the new song at the beginning. $trace');
      expect(snap.playing, isTrue, reason: 'a skip must keep playing. $trace');
    }

    // One element for the whole session. See _elementsBuilt.
    expect(_elementsBuilt(), 1,
        reason: 'the web player must keep its one media element across track '
            'changes, or the browser asks for a tap again on every song. $trace '
            '|| AUDIO: ${_audioLog()}');

    // The half of the problem a tap cannot cover: when a song finishes, or a download
    // lands, nobody has touched anything, so the browser is within its rights to
    // refuse. It only works if the element that was already allowed to play is reused.
    final items = player.items;
    _mark('auto-advance');
    await player.playAt(0);
    await settle(tester, seconds: 5);
    expect(app.debugPlayerSnapshot()!.loadedTrackId, items[0].id);

    // Right up to the end, then let it run off the end by itself.
    final len = items[0].durationMs!;
    await player.seek(Duration(milliseconds: len - 4000));
    await settle(tester, seconds: 14);

    snap = app.debugPlayerSnapshot()!;
    expect(snap.loadedTrackId, items[1].id,
        reason: 'the next song must load when the previous one ends '
            '|| AUDIO: ${_audioLog()}');
    expect(snap.playing, isTrue,
        reason: 'and it must actually be playing, with nothing tapped '
            '|| AUDIO: ${_audioLog()}');
    expect(snap.needsGesture, isFalse, reason: 'no tap should have been needed');
    expect(_elementsBuilt(), 1,
        reason: 'still one element || AUDIO: ${_audioLog()}');
  });
}
