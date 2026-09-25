import 'dart:typed_data';

/// Nowhere to put a rendered sound. The booth still mixes; it just cannot add
/// anything of its own, and FxChannel says so rather than pretending.
Future<String?> fxSource(Uint8List wav, String key) async => null;

/// Nothing was kept, so there is nothing to let go of.
void fxForget() {}
