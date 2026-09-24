import 'package:flutter/widgets.dart';

import '../state/app_state.dart';

/// A browser: there are no programs to run.
const canFetchMusicHere = false;

Future<void> resumeFetching(AppState app) async {}

Future<void> stopFetching() async {}

String? fetchedHerePath(int trackId) => null;

Widget thisComputerCard() => const SizedBox.shrink();

Future<void> fetchHereNow(List<int> trackIds) async {}
