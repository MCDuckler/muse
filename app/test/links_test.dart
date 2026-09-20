// Arriving by link.
//
// Everything in this library comes from somewhere else and nothing ever left it: on a
// box four people share there was no way to say "listen to this". A link is this
// server with a path on it, and the half checked here is the half that is easy to get
// wrong — reading it once, and knowing what it points at.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/api/client.dart';
import 'package:muse/src/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    app = AppState()..api = ApiClient(baseUrl: 'http://example.invalid');
  });

  test('a link is read once and then it is gone', () {
    app.arrivedAt('/p/12');
    expect(app.takeTheLink(), '/p/12');
    expect(app.takeTheLink(), isNull,
        reason: 'a link is a thing that happened, not a place the app stays');
  });

  test('opening the app at its front door is not a link', () {
    app.arrivedAt('/');
    expect(app.takeTheLink(), isNull);
    app.arrivedAt('');
    expect(app.takeTheLink(), isNull);
  });

  test('the last link wins, which is the tab you actually opened', () {
    app.arrivedAt('/p/12');
    app.arrivedAt('/r/Bicep');
    expect(app.takeTheLink(), '/r/Bicep');
  });
}
