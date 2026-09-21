/// How long ago, in words.
///
/// Dates on a screen are a small unkindness: "2026-09-14 22:03" is a fact somebody has
/// to do arithmetic on to use. What anybody actually wants to know is whether it was
/// just now, this morning, or long enough ago not to matter.
String ago(DateTime? when, {String never = 'never'}) {
  if (when == null) return never;
  final seconds = DateTime.now().difference(when).inSeconds;
  if (seconds < 0) return 'just now';           // a clock somewhere is ahead
  if (seconds < 45) return 'just now';
  if (seconds < 90) return 'a minute ago';
  final minutes = seconds ~/ 60;
  if (minutes < 55) return '$minutes minutes ago';
  final hours = (minutes / 60).round();
  if (hours == 1) return 'an hour ago';
  if (hours < 24) return '$hours hours ago';
  final days = (hours / 24).round();
  if (days == 1) return 'yesterday';
  if (days < 7) return '$days days ago';
  if (days < 14) return 'last week';
  if (days < 60) return '${(days / 7).round()} weeks ago';
  if (days < 365) return '${(days / 30).round()} months ago';
  final years = (days / 365).round();
  return years == 1 ? 'a year ago' : '$years years ago';
}
