import 'package:flutter/widgets.dart';

import '../state/app_state.dart';

/// A browser: it cannot open a connection to YouTube for anybody.
const canOpenDoorHere = false;

Future<void> openDoorHere(AppState app) async {}

Future<void> shutDoorHere() async {}

Widget doorHereTile() => const SizedBox.shrink();

Widget doorHereCard() => const SizedBox.shrink();
