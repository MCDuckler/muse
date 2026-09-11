/// Nowhere to say it. Android and iOS apps have a real media session of their own —
/// this exists for the web, where the page has to ask the browser for one.
void describeToTheBrowser({
  required String title,
  required String artist,
  required String album,
  String? artwork,
  required bool playing,
  void Function()? onPlay,
  void Function()? onPause,
  void Function()? onNext,
  void Function()? onPrevious,
}) {}

void nothingIsPlaying() {}
