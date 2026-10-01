import 'package:flutter/widgets.dart';

/// The engine check drives libmpv directly, which a browser does not have: see
/// engine_check.dart, which is what every other platform gets.
Future<void> openEngineCheck(BuildContext context) async {}
