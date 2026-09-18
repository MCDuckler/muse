// Starting up at all.
//
// Every test in here drove an AppState that had been handed its pieces by hand, so
// nothing ever ran boot() — and boot() is the one path every launch takes. A setting
// read into the api client twelve lines before that client was built threw on the
// first frame and showed a white page, on the web and on the phone, and the whole
// suite stayed green.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a cold start reads its settings and builds a client', () async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await app.boot();

    expect(app.ready, isTrue, reason: 'it got to the end');
    expect(app.api.baseUrl, isNotEmpty, reason: 'and there is a server to talk to');
    expect(app.api.discLabel, app.discLabel,
        reason: 'the one setting the client also needs reached it');
  });

  test('a start with settings already saved keeps them', () async {
    SharedPreferences.setMockInitialValues({
      'muse.discLabel': 0.6,
      'muse.homeTab': 2,
      'muse.deskDock': false,
      'muse.coverScale': 0.9,
    });
    final app = AppState();
    await app.boot();

    expect(app.discLabel, closeTo(0.6, 0.001));
    expect(app.api.discLabel, closeTo(0.6, 0.001),
        reason: 'the record is drawn with the label that was chosen');
    expect(app.homeTab, 2);
    expect(app.deskDock, isFalse);
    expect(app.coverScale, closeTo(0.9, 0.001));
  });

  test('nonsense in the settings is clamped rather than obeyed', () async {
    SharedPreferences.setMockInitialValues({
      'muse.discLabel': 40.0,
      'muse.homeTab': 99,
      'muse.coverScale': -3.0,
    });
    final app = AppState();
    await app.boot();

    expect(app.discLabel, lessThanOrEqualTo(0.92));
    expect(app.homeTab, inInclusiveRange(0, 3));
    expect(app.coverScale, inInclusiveRange(0.5, 1.0));
  });
}
