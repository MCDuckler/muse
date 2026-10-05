// When a phone's door to YouTube is open (worker/door_here_io.dart): while the app is on
// the screen or playing, shut a minute after it is neither, never knocking again where it
// was turned away, and opened afresh with a new token.
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/app_state.dart';
import 'package:muse/src/worker/door_here_io.dart';
import 'package:muse/src/worker/exit_tunnel.dart';

class _Tunnel extends ExitTunnel {
  _Tunnel() : super(url: () => Uri.parse('ws://x'), token: () => 't', hello: () => {});
  int starts = 0;
  int stops = 0;
  int hellos = 0;
  bool _open = false;

  @override
  bool get wanted => _open;

  @override
  Future<void> start() async {
    starts += 1;
    _open = true;
    state = ExitState.open;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stops += 1;
    _open = false;
    state = ExitState.off;
    notifyListeners();
  }

  @override
  void sayHello() => hellos += 1;

  void turnAway() {
    _open = false;
    problem = 'an admin has kept this device out of the pool';
    state = ExitState.refused;
    notifyListeners();
  }
}

void _tell(AppState app) {
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  app.notifyListeners();
}

Future<void> _away(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  await tester.pump();
}

Future<void> _back(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pump();
}

void main() {
  late AppState app;
  late _Tunnel tunnel;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    app = AppState()..api = (ApiClient(baseUrl: 'http://example.invalid')..token = 't1');
    app.user = 'chris';
    tunnel = _Tunnel();
  });

  testWidgets('open while on the screen, shut a minute after it is not', (tester) async {
    final door = await DoorHere.forTest(app, tunnel);
    await tester.pump();
    expect(tunnel.starts, 1);

    await _away(tester);
    await tester.pump(const Duration(seconds: 59));
    expect(tunnel.stops, 0, reason: 'a minute, not at once');
    await tester.pump(const Duration(seconds: 2));
    expect(tunnel.stops, 1);

    await _back(tester);
    expect(tunnel.starts, 2);
    door.dispose();
  });

  testWidgets('playing keeps it open out of sight', (tester) async {
    final door = await DoorHere.forTest(app, tunnel);
    door.heardPlaying(true);
    await _away(tester);
    await tester.pump(const Duration(minutes: 5));
    expect(tunnel.stops, 0);

    door.heardPlaying(false);
    await tester.pump(const Duration(seconds: 61));
    expect(tunnel.stops, 1);
    door.dispose();
  });

  testWidgets('turned away: not again until switched on by hand or signed in afresh',
      (tester) async {
    final door = await DoorHere.forTest(app, tunnel);
    expect(tunnel.starts, 1);
    tunnel.turnAway();
    _tell(app);
    await _away(tester);
    await _back(tester);
    expect(tunnel.starts, 1, reason: 'no knocking on a door that said no');
    expect(door.line, contains('admin'));

    await door.set(on: true);
    expect(tunnel.starts, 2);

    tunnel.turnAway();
    app.api.token = 't2';
    _tell(app);
    expect(tunnel.starts, 3, reason: 'a new token is a new question');
    door.dispose();
  });

  testWidgets('a new token opens it afresh, signing out shuts it', (tester) async {
    final door = await DoorHere.forTest(app, tunnel);
    expect(tunnel.starts, 1);
    app.api.token = 't2';
    _tell(app);
    await tester.pump();
    expect((tunnel.stops, tunnel.starts), (1, 2));

    app.user = null;
    _tell(app);
    await tester.pump();
    expect(tunnel.stops, 2);
    expect(tunnel.wanted, isFalse);
    door.dispose();
  });

  testWidgets('switched off, it stays shut', (tester) async {
    final door = await DoorHere.forTest(app, tunnel);
    await door.set(on: false);
    expect(tunnel.wanted, isFalse);
    await _away(tester);
    await _back(tester);
    expect(tunnel.wanted, isFalse);
    expect((await SharedPreferences.getInstance()).getBool('muse.door.on'), isFalse);
    door.dispose();
  });

  testWidgets('tells the server when the network or the data rule changes', (tester) async {
    final door = await DoorHere.forTest(app, tunnel,
        now: [ConnectivityResult.mobile],
        changes: Stream.value([ConnectivityResult.wifi, ConnectivityResult.vpn]));
    expect(door.hello()['network'], 'cellular');
    await tester.pump();
    expect(door.network, 'wifi');
    expect(tunnel.hellos, 1);

    await door.set(mobileData: false);
    expect(door.hello()['mobile_data'], false);
    expect(tunnel.hellos, 2);
    door.dispose();
  });
}
