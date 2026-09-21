import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/when.dart';

/// The point of these is the boundaries. The words in between are taste; the places
/// where one word becomes another are where a wrong answer looks like a bug — a device
/// heard from forty seconds ago should not be "0 minutes ago", and one heard from an
/// hour ago should not be "60 minutes ago".
void main() {
  String since(Duration d) => ago(DateTime.now().subtract(d));

  test('nothing to say when there is no time', () {
    expect(ago(null), 'never');
    expect(ago(null, never: 'not yet'), 'not yet');
  });

  test('a clock that is ahead of us is still now', () {
    expect(ago(DateTime.now().add(const Duration(minutes: 5))), 'just now');
  });

  test('seconds are just now', () {
    expect(since(const Duration(seconds: 3)), 'just now');
    expect(since(const Duration(seconds: 44)), 'just now');
  });

  test('a minute, then minutes', () {
    expect(since(const Duration(seconds: 60)), 'a minute ago');
    expect(since(const Duration(minutes: 2)), '2 minutes ago');
    expect(since(const Duration(minutes: 54)), '54 minutes ago');
  });

  test('an hour, then hours', () {
    expect(since(const Duration(minutes: 58)), 'an hour ago');
    expect(since(const Duration(hours: 5)), '5 hours ago');
  });

  test('yesterday, then days, then weeks', () {
    expect(since(const Duration(hours: 26)), 'yesterday');
    expect(since(const Duration(days: 3)), '3 days ago');
    expect(since(const Duration(days: 8)), 'last week');
    expect(since(const Duration(days: 21)), '3 weeks ago');
  });

  test('months and years', () {
    expect(since(const Duration(days: 90)), '3 months ago');
    expect(since(const Duration(days: 400)), 'a year ago');
    expect(since(const Duration(days: 800)), '2 years ago');
  });
}
