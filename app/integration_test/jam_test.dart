// Does listening together actually mean listening together?
//
// A jam is two devices, which a test cannot have — so the app under test is one of
// them and a second account, driven through the API, is the other. Both directions are
// covered: the app as the host (somebody else's play button reaches it, and what it
// plays reaches the server), and the app as a guest (the room's transport arrives and
// the app's own player follows it, in the same song at the same place).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:muse/main.dart' as app;
import 'package:muse/src/api/client.dart';
import 'package:muse/src/api/models.dart';

const server =
    String.fromEnvironment('MUSE_SERVER', defaultValue: 'https://89-58-49-140.nip.io');
const user = String.fromEnvironment('MUSE_USER', defaultValue: 'chris');
const pass = String.fromEnvironment('MUSE_PASS');
const otherUser = String.fromEnvironment('MUSE_GUEST_USER', defaultValue: 'dar');
const otherPass = String.fromEnvironment('MUSE_GUEST_PASS');

Future<void> settle(WidgetTester tester, {int seconds = 3}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    tester.takeException();
  }
}

/// Wait for something to become true, pumping while it does not. Everything here goes
/// through a server and an event stream, so "after a fixed sleep" is a flaky test and
/// "as soon as it happens" is not.
Future<bool> until(WidgetTester tester, bool Function() done, {int seconds = 20}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    if (done()) return true;
    await tester.pump(const Duration(milliseconds: 100));
    tester.takeException();
  }
  return done();
}

/// What the room has been told, once it has been told something that fits. Everything
/// here crosses a server, so waiting for the answer beats sleeping and hoping.
Future<JamPlayback?> roomSays(WidgetTester tester, bool Function(JamPlayback) fits,
    {int seconds = 20}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    final state = (await _other!.currentJam())?.playback;
    if (state != null && fits(state)) return state;
    await settle(tester, seconds: 1);
  }
  return null;
}

ApiClient? _other;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final stamp = DateTime.now().millisecondsSinceEpoch;
  int? hostQueue;
  int? otherQueue;
  ApiClient? other;

  tearDownAll(() async {
    final state = app.debugAppState;
    if (state?.jam != null) {
      try {
        await state!.leaveJam();
      } catch (_) {}
    }
    if (other != null && otherQueue != null) {
      try {
        await other!.deleteQueue(otherQueue!);
      } catch (_) {}
    }
    if (state != null && hostQueue != null) {
      try {
        await state.api.deleteQueue(hostQueue!);
      } catch (_) {}
    }
  });

  testWidgets('a jam moves the host from anybody in the room', (tester) async {
    app.main();
    await settle(tester, seconds: 4);

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2), reason: 'login screen should be up');
    await tester.enterText(fields.at(0), user);
    await tester.enterText(fields.at(1), pass);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await settle(tester, seconds: 8);
    await binding.takeScreenshot('J-signed-in');

    final state = app.debugAppState!;
    final api = state.api;

    // The other person in the room. Nothing about them is simulated: it is a second
    // account on the same server, holding its own token.
    other = ApiClient(baseUrl: server);
    other!.token = await other!.login(otherUser, otherPass, 'jam-probe');
    _other = other;

    final library = await api.libraryTracks(limit: 200, readyOnly: true);
    final picks = <Track>[];
    for (final t in library.items) {
      if (t.state != 'ready' || t.durationMs == null) continue;
      if (picks.any((c) => c.id == t.id)) continue;
      picks.add(t);
      if (picks.length == 3) break;
    }
    expect(picks.length, 3, reason: 'need three downloaded tracks');

    // ---------------------------------------------------------------- app as host
    final queue = await api.createQueue('jam-host-$stamp');
    hostQueue = queue.id;
    await api.addToQueue(queue.id, picks.map((t) => t.id).toList());
    await state.openQueue(queue.id);
    await settle(tester, seconds: 3);
    await state.player!.playAt(0);
    await settle(tester, seconds: 6);
    expect(state.player!.last?.playing, isTrue, reason: 'nothing to share if it is silent');

    await state.startJam();
    await settle(tester, seconds: 3);
    await binding.takeScreenshot('J-jam-started');
    expect(state.jam, isNotNull);
    expect(state.jam!.isHost, isTrue);

    // What the host is playing reaches the server without anybody asking for it.
    final room = await other!.joinJam(state.jam!.code);
    expect(room.queueId, queue.id);
    var seen = await roomSays(tester, (p) => p.trackId == picks[0].id && p.playing);
    expect(seen, isNotNull,
        reason: 'the host must publish the song it is on, and that it is playing');
    await binding.takeScreenshot('J-published');

    // Somebody else's pause reaches this device.
    await other!.jamControl(state.jam!.id, 'pause');
    expect(
        await until(tester, () => !(state.player!.last?.playing ?? true)),
        isTrue,
        reason: 'a guest pressing pause must stop the host');
    await binding.takeScreenshot('J-guest-paused');

    await other!.jamControl(state.jam!.id, 'play');
    expect(await until(tester, () => state.player!.last?.playing ?? false), isTrue,
        reason: 'and their play must start it again');

    final was = state.player!.current!.id;
    await other!.jamControl(state.jam!.id, 'next');
    expect(await until(tester, () => state.player!.current?.id != was), isTrue,
        reason: 'a guest skipping must move the host on');
    await binding.takeScreenshot('J-guest-skipped');

    // And the host says so, rather than leaving the room on the old song.
    final moved = state.player!.current!.id;
    seen = await roomSays(tester, (p) => p.trackId == moved);
    expect(seen, isNotNull,
        reason: 'the room must be told what the host moved to');

    // And the queue is shared both ways: what a guest adds lands in the host's queue.
    final theirPick = picks[2];
    await other!.addToQueue(queue.id, [theirPick.id], mode: 'next');
    expect(
        await until(tester,
            () => state.player!.items.any((t) => t.id == theirPick.id)),
        isTrue,
        reason: 'a guest adding a song must reach the host\'s player');
    await binding.takeScreenshot('J-guest-added');

    await state.leaveJam();          // the host leaving ends it
    await settle(tester, seconds: 3);
    await binding.takeScreenshot('J-host-left');
    expect(state.jam, isNull);
  });

  testWidgets('a jam carries the room to this device too', (tester) async {
    final state = app.debugAppState!;
    final api = state.api;
    final library = await api.libraryTracks(limit: 200, readyOnly: true);
    final picks = <Track>[];
    for (final t in library.items) {
      if (t.state != 'ready' || t.durationMs == null) continue;
      if (picks.any((c) => c.id == t.id)) continue;
      picks.add(t);
      if (picks.length == 3) break;
    }

    // Now the other way round: the second account hosts, and this app follows.
    final theirs = await other!.createQueue('jam-guest-$stamp');
    otherQueue = theirs.id;
    await other!.addToQueue(theirs.id, picks.map((t) => t.id).toList());
    final theirJam = await other!.startJam(theirs.id);

    await state.joinJam(theirJam.code);
    await settle(tester, seconds: 4);
    final says = await other!.currentJam();
    expect(state.jam!.isHost, isFalse,
        reason: 'joined jam=${state.jam?.id} code=${state.jam?.code} '
            'host=${state.jam?.host} queue=${state.jam?.queueId} '
            'theirJam=${theirJam.id}/${theirJam.code} theirQueue=${theirs.id} '
            'darSees=${says?.id}/${says?.code}');
    String? reach;
    try {
      final direct = await api.queue(theirs.id);
      reach = 'read ${direct.id} with ${direct.items.length} items';
    } catch (e) {
      reach = 'could not read it: $e';
    }
    expect(state.activeQueue?.id, theirs.id,
        reason: 'a guest listens to the host\'s queue, not their own. '
            'jam=${state.jam?.id} jamQueue=${state.jam?.queueId} '
            'active=${state.activeQueue?.id} theirs=${theirs.id} · $reach');

    // The room is halfway through the second song: the app must arrive there, not at
    // the top of the first.
    await other!.pushJamPlayback(theirJam.id,
        trackId: picks[1].id, positionMs: 30_000, playing: true);

    expect(await until(tester, () => state.player!.current?.id == picks[1].id),
        isTrue, reason: 'a guest must move to the song the room is on');
    expect(await until(tester, () => state.player!.last?.playing ?? false), isTrue,
        reason: 'and play it');
    expect(
        await until(
            tester,
            () =>
                (state.player!.last?.position ?? Duration.zero) >
                const Duration(seconds: 20)),
        isTrue,
        reason: 'and be where the room is, not at the beginning. '
            'at=${state.player!.last?.position}');

    // A pause from the room stops this device too.
    await other!.pushJamPlayback(theirJam.id,
        trackId: picks[1].id, positionMs: 42_000, playing: false);
    expect(await until(tester, () => !(state.player!.last?.playing ?? true)), isTrue,
        reason: 'the room pausing must pause the guest');

    await state.leaveJam();
    await settle(tester, seconds: 2);
    expect(state.jam, isNull);
  });
}
