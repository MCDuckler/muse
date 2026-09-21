import 'package:flutter/foundation.dart';

/// A list that arrives a page at a time.
///
/// The library lists used to ask once and draw whatever came back, which was the
/// server's default page: two hundred of ten thousand records, three hundred of nine
/// thousand artists, and nothing anywhere saying the list went on. It simply stopped
/// partway through the alphabet, which reads as a bug in the library rather than as a
/// page boundary — because it is one.
///
/// So: hold what has arrived, know how many there are in all, and fetch the next page
/// when the bottom of the list comes into view.
class Paged<T> extends ChangeNotifier {
  Paged({required this.fetch, this.pageSize = 200});

  /// One page, from wherever the list has got to.
  final Future<({List<T> items, int total})> Function(int offset, int limit) fetch;
  final int pageSize;

  final List<T> items = [];
  int total = 0;
  Object? error;
  bool _loading = false;
  bool _done = false;

  bool get loading => _loading;
  bool get isEmpty => items.isEmpty && !_loading && error == null;

  /// Whether anything is still to come. Counted rather than guessed: a page that comes
  /// back short is the end even when the total says otherwise, which is what happens
  /// while somebody is adding music as the list is read.
  bool get more => !_done && (total == 0 || items.length < total);

  /// The first page, or all of it again after a pull to refresh.
  ///
  /// What is on screen stays there until the new rows arrive. Clearing first made a
  /// refresh a flash of nothing — the list vanished, the scroll jumped to the top, and
  /// the same rows came back a moment later, which reads as the app losing your place
  /// rather than as it checking.
  Future<void> reload() async {
    _done = false;
    error = null;
    // Ask for as much as was already on screen, so a refresh does not throw away
    // everything somebody scrolled to.
    final had = items.length;
    await _get(limit: had > pageSize ? had : pageSize, replacing: true);
  }

  /// Everything up to and including row [index], fetched a page at a time.
  ///
  /// For going somewhere in the list rather than reading down it: the letter T starts
  /// at row 1,640, and the rows between here and there have to have arrived before
  /// the list can be put there. In pages, because the server hands out no more than a
  /// page however much is asked for — and a short page is how the end is recognised.
  Future<void> reach(int index) async {
    while (items.length <= index && more && error == null) {
      if (_loading) {
        // Something is already on its way; let it land and look again.
        await Future<void>.delayed(const Duration(milliseconds: 40));
        continue;
      }
      await _get(limit: pageSize);
    }
  }

  /// The next page, if there is one and nothing is already in flight.
  Future<void> next() async {
    if (_loading || !more) return;
    await _get(limit: pageSize);
  }

  Future<void> _get({required int limit, bool replacing = false}) async {
    _loading = true;
    notifyListeners();
    try {
      final page = await fetch(replacing ? 0 : items.length, limit);
      if (replacing) items.clear();
      items.addAll(page.items);
      total = page.total;
      if (page.items.length < limit) _done = true;
      error = null;
    } catch (e) {
      error = e;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }
}
