// When a phone's door to YouTube is open (worker/door_here_io.dart): while the app is on
// the screen or playing, shut a minute after it is neither, never knocking again where it
// was turned away, and opened afresh with a new token.
import 'dart:io';

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

(String, List<InternetAddress>) _if(String name, List<String> ips) =>
    (name, [for (final ip in ips) InternetAddress(ip)]);

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

  test('Wi-Fi or the phone\'s data, by which interfaces have an address', () {
    String n(List<(String, List<InternetAddress>)> up) => DoorHere.networkNamed(up);
    expect(n([_if('lo0', ['127.0.0.1']), _if('pdp_ip0', ['10.1.2.3']),
              _if('en0', ['192.168.1.20'])]), 'wifi', reason: 'an iPhone on Wi-Fi keeps its data up');
    expect(n([_if('pdp_ip0', ['10.1.2.3']), _if('en0', ['fe80::1'])]), 'cellular',
        reason: 'a link-local address is not a network');
    expect(n([_if('rmnet_data0', ['2a01:598:1::5'])]), 'cellular');
    expect(n([_if('ccmni1', ['10.0.0.9'])]), 'cellular');
    expect(n([_if('wlan0', ['192.168.0.7']), _if('rmnet_data0', ['10.0.0.9'])]), 'wifi');
    expect(n([_if('tun0', ['10.8.0.2'])]), 'unknown');
    expect(n([]), 'none');
  });

  testWidgets('tells the server when the network or the data rule changes', (tester) async {
    final door = await DoorHere.forTest(app, tunnel,
        now: 'cellular', changes: Stream.value('wifi'));
    expect(door.hello()['network'], 'cellular');
    await tester.pump();
    expect(door.network, 'wifi');
    expect(tunnel.hellos, 1);

    expect(door.hello()['pulls'], 1, reason: 'it fetches a song itself when told where');
    await door.set(mobileData: false);
    expect(door.hello()['mobile_data'], false);
    expect(tunnel.hellos, 2);
    door.dispose();
  });
}
