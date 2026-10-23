import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// No pictures where there is nowhere to keep them.
class FaveThumbs {
  const FaveThumbs._();
  static Future<void> ready() async {}
  static Future<void> keep(String id, Uint8List png) async {}
  static Future<void> forget(String id) async {}
  static Future<void> prune(Set<String> ids) async {}
  static ImageProvider? image(String id) => null;
}
