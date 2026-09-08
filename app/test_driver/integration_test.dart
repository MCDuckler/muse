import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Screenshots are how a change to the artwork gets looked at rather than guessed at:
/// the test calls takeScreenshot(name) and the picture lands in build/screenshots.
Future<void> main() => integrationDriver(
      onScreenshot: (String name, List<int> bytes, [Map<String, Object?>? args]) async {
        final file = File('build/screenshots/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
        return true;
      },
    );
