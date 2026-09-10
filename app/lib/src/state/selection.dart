import 'package:flutter/foundation.dart';

/// Which songs are picked out, and where.
///
/// Doing something to twenty songs used to mean doing it twenty times: open the row,
/// choose the action, wait, open the next one. Selection is the missing verb — hold a
/// row to start, tap to add, and then act on the lot.
///
/// It is scoped to a list rather than global: a selection made in the queue means
/// nothing on the artist page, and walking away from a list ends it rather than
/// leaving a hidden state to come back to. `where` is whatever identifies the list —
/// "queue:12", "playlist:3", "album:Low".
class Selection extends ChangeNotifier {
  String? _where;
  final _picked = <int>{};

  /// The rows picked out, in the order they were picked.
  final _order = <int>[];

  bool get active => _where != null;
  int get count => _picked.length;
  String? get where => _where;

  /// Selected ids, in the order the person chose them.
  List<int> get ids => List.unmodifiable(_order);

  bool has(int trackId) => _picked.contains(trackId);

  /// True when this list is the one being selected in.
  bool inside(String where) => _where == where;

  void start(String where, int trackId) {
    if (_where != where) {
      _picked.clear();
      _order.clear();
      _where = where;
    }
    toggle(where, trackId);
  }

  void toggle(String where, int trackId) {
    if (_where != where) return start(where, trackId);
    if (!_picked.add(trackId)) {
      _picked.remove(trackId);
      _order.remove(trackId);
    } else {
      _order.add(trackId);
    }
    if (_picked.isEmpty) {
      _where = null;
    }
    notifyListeners();
  }

  /// Everything in the list, for the "select all" that any selection needs.
  void selectAll(String where, Iterable<int> trackIds) {
    _where = where;
    for (final id in trackIds) {
      if (_picked.add(id)) _order.add(id);
    }
    if (_picked.isEmpty) _where = null;
    notifyListeners();
  }

  void clear() {
    if (_where == null && _picked.isEmpty) return;
    _where = null;
    _picked.clear();
    _order.clear();
    notifyListeners();
  }

  /// Leaving a list ends its selection, but only its own: a screen that pops while a
  /// different list is being selected in must not clear that one.
  void leave(String where) {
    if (_where == where) clear();
  }
}
