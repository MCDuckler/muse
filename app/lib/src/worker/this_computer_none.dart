import 'package:flutter/widgets.dart';

import '../state/app_state.dart';

/// A browser: there are no programs to run.
const canFetchMusicHere = false;

Future<void> resumeFetching(AppState app) async {}

Future<void> stopFetching() async {}

Widget thisComputerPage() => const SizedBox.shrink();
