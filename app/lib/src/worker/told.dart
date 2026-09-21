/// Something that says when it has changed.
///
/// What Flutter's ChangeNotifier is, without Flutter: the downloader runs inside the
/// app and also by itself in a program with no window — see bin/wetowl_fetch.dart —
/// and a program with no window cannot import a widget library to borrow forty lines
/// from it. The names are the same, so the app listens to it as it would to any other.
class Told {
  final _listeners = <void Function()>[];
  bool _gone = false;

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void notifyListeners() {
    if (_gone) return;
    // A copy: a listener may well take itself off the list while being told.
    for (final l in _listeners.toList()) {
      if (_listeners.contains(l)) l();
    }
  }

  void dispose() {
    _gone = true;
    _listeners.clear();
  }
}
