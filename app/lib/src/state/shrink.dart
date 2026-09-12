import 'dart:typed_data';
import 'dart:ui' as ui;

/// Make a picture small enough to send.
///
/// What comes out of a phone's camera roll is twelve megapixels and several megabytes
/// — for a face drawn at forty pixels across. Sending it as it is means a long upload
/// on a phone connection, a server that has to refuse anything over twelve megabytes,
/// and a browser holding the whole thing in memory while it goes. Decoding it once and
/// sending a thousand pixels of it costs a fraction of that and looks identical.
///
/// Returns the original bytes if anything about the picture cannot be read: the server
/// squares and shrinks it too, so this is an optimisation and never the only line of
/// defence.
Future<Uint8List> shrinkForUpload(Uint8List raw, {int longest = 1024}) async {
  try {
    final codec = await ui.instantiateImageCodec(raw);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final side = image.width > image.height ? image.width : image.height;
    if (side <= longest) {
      image.dispose();
      codec.dispose();
      return raw;
    }

    final scale = longest / side;
    final width = (image.width * scale).round();
    final height = (image.height * scale).round();
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final small = await picture.toImage(width, height);
    final data = await small.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    small.dispose();
    picture.dispose();
    codec.dispose();
    if (data == null) return raw;
    return data.buffer.asUint8List();
  } catch (_) {
    // A picture this platform cannot decode — an iPhone's HEIC, most likely. The
    // server has a decoder for those.
    return raw;
  }
}
