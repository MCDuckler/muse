import 'dart:math' as math;

/// How the wall of records is laid out: how many across, how big, and whether there is
/// room to write under them.
///
/// Left alone it is what it always was — as many as fit at a comfortable size. Asked for
/// a number, it is that number, within reason: a cover under seventy pixels is not a
/// cover any more, so a phone asked for nine gets the most it can show. And a small
/// cover loses its caption rather than keeping one nobody could read: two words and an
/// ellipsis under every tile is noise, and a wall of covers alone is what a record shop
/// looks like from the door.
class AlbumGrid {
  const AlbumGrid._(this.across, this.tile, this.extent, this.captions, this.gapAcross,
      this.gapDown);

  factory AlbumGrid.of({
    required double usable,
    required bool wide,
    int? chosen,
    double textScale = 1,
  }) {
    final maxTile = wide ? 230.0 : 190.0;
    var gapAcross = wide ? 18.0 : 12.0, gapDown = wide ? 22.0 : 16.0;
    final int auto = (usable / (maxTile + gapAcross)).ceil().clamp(1, 99).toInt();
    final most = mostAcross(usable);
    final int across = chosen == null ? auto : chosen.clamp(1, math.max(1, most)).toInt();
    if (across > auto + 1) {
      // Small covers want small gutters, or the page is mostly gutter.
      gapAcross = wide ? 12.0 : 8.0;
      gapDown = wide ? 14.0 : 10.0;
    }
    final tile = (usable - gapAcross * (across - 1)) / across;
    final captions = tile >= 96;
    // What is written under a cover is two lines of type and does not shrink with
    // the cover, so it is given the room type needs rather than a share of the tile.
    final under = captions ? math.max(tile * 0.351, 8 + 40 * textScale.clamp(1.0, 2.5)) : 0.0;
    return AlbumGrid._(across, tile, tile + under, captions, gapAcross, gapDown);
  }

  /// The most that can go across this much room.
  static int mostAcross(double usable) =>
      ((usable + 8) / (70 + 8)).floor().clamp(1, 12).toInt();

  final int across;
  final double tile;

  /// How tall a cell is, cover and caption together.
  final double extent;
  final bool captions;
  final double gapAcross;
  final double gapDown;

  /// From the top of one row to the top of the next.
  double get stride => extent + gapDown;
}
