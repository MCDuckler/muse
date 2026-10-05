/// One plain m4a out of a fragmented one: what yt-dlp's FixupM4a does with ffmpeg,
/// done without ffmpeg, so a phone can play a song YouTube sends in pieces.
///
/// YouTube's audio comes as DASH: a `moov` that describes no samples at all, then
/// dozens of `moof`+`mdat` fragments, each listing its own samples. Plenty of players
/// manage that, but not all of them, and not always with a duration or a working seek.
/// So the samples are gathered into one `mdat` and described once, in a `moov` placed
/// in front (to start playing before the end has arrived), with nothing re-encoded.
/// Each fragment's run of samples becomes one chunk.
///
/// Only what a single audio track needs: one `trak`, no composition offsets. Anything
/// else answers null, and the caller keeps the file as it came.
library;

import 'dart:convert';
import 'dart:typed_data';

class _Box {
  _Box(this.type, this.start, this.header, this.end);
  final String type;
  final int start;
  final int header;
  final int end;
  int get body => start + header;
}

List<_Box> _boxes(ByteData d, int from, int to) {
  final out = <_Box>[];
  var at = from;
  while (at + 8 <= to) {
    var size = d.getUint32(at);
    final type = String.fromCharCodes(Uint8List.sublistView(d, at + 4, at + 8));
    var header = 8;
    if (size == 1) {
      if (at + 16 > to) break;
      size = d.getUint64(at + 8);
      header = 16;
    } else if (size == 0) {
      size = to - at;
    }
    if (size < header || at + size > to) break;
    out.add(_Box(type, at, header, at + size));
    at += size;
  }
  return out;
}

_Box? _first(List<_Box> boxes, String type) {
  for (final b in boxes) {
    if (b.type == type) return b;
  }
  return null;
}

Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);

Uint8List _box(String type, List<List<int>> parts) {
  final size = 8 + parts.fold<int>(0, (n, p) => n + p.length);
  final b = BytesBuilder(copy: false)
    ..add(_u32(size))
    ..add(ascii.encode(type));
  for (final p in parts) {
    b.add(p);
  }
  return b.takeBytes();
}

Uint8List _full(String type, int version, int flags, List<List<int>> parts) =>
    _box(type, [_u32((version << 24) | flags), ...parts]);

/// The plain m4a, or null when [src] is not a fragmented one this understands.
Uint8List? wholeM4a(Uint8List src) {
  try {
    return _whole(src);
  } on RangeError {
    return null;                              // a box claiming more than is there
  }
}

Uint8List? _whole(Uint8List src) {
  final d = ByteData.sublistView(src);
  final top = _boxes(d, 0, src.length);
  final moov = _first(top, 'moov');
  if (moov == null || _first(top, 'moof') == null) return null;

  final inMoov = _boxes(d, moov.body, moov.end);
  final mvhd = _first(inMoov, 'mvhd');
  final traks = inMoov.where((b) => b.type == 'trak').toList();
  if (mvhd == null || traks.length != 1) return null;
  final trak = traks.single;
  final inTrak = _boxes(d, trak.body, trak.end);
  final tkhd = _first(inTrak, 'tkhd');
  final mdia = _first(inTrak, 'mdia');
  if (tkhd == null || mdia == null) return null;
  final inMdia = _boxes(d, mdia.body, mdia.end);
  final mdhd = _first(inMdia, 'mdhd');
  final minf = _first(inMdia, 'minf');
  if (mdhd == null || minf == null) return null;
  final inMinf = _boxes(d, minf.body, minf.end);
  final stbl = _first(inMinf, 'stbl');
  if (stbl == null) return null;
  final stsd = _first(_boxes(d, stbl.body, stbl.end), 'stsd');
  if (stsd == null) return null;

  // The defaults a fragment may lean on.
  var trexDuration = 0, trexSize = 0;
  final mvex = _first(inMoov, 'mvex');
  if (mvex != null) {
    final trex = _first(_boxes(d, mvex.body, mvex.end), 'trex');
    if (trex != null) {
      // version+flags, track_ID, sample_description_index, duration, size, flags
      trexDuration = d.getUint32(trex.body + 12);
      trexSize = d.getUint32(trex.body + 16);
    }
  }

  final sizes = <int>[];
  final durations = <int>[];
  final chunks = <(int start, int length, int samples)>[];
  for (final moof in top.where((b) => b.type == 'moof')) {
    final trafs = _boxes(d, moof.body, moof.end).where((b) => b.type == 'traf').toList();
    if (trafs.length != 1) return null;
    final inTraf = _boxes(d, trafs.single.body, trafs.single.end);
    final tfhd = _first(inTraf, 'tfhd');
    if (tfhd == null) return null;
    final tf = d.getUint32(tfhd.body) & 0xffffff;
    var at = tfhd.body + 8;                   // past version+flags and track_ID
    var base = moof.start;                    // 0x20000, or no base given at all
    if (tf & 0x1 != 0) {
      base = d.getUint64(at);
      at += 8;
    }
    if (tf & 0x2 != 0) at += 4;
    var defDuration = trexDuration, defSize = trexSize;
    if (tf & 0x8 != 0) {
      defDuration = d.getUint32(at);
      at += 4;
    }
    if (tf & 0x10 != 0) {
      defSize = d.getUint32(at);
      at += 4;
    }
    var next = base;                          // where a run with no offset of its own starts
    for (final trun in inTraf.where((b) => b.type == 'trun')) {
      final rf = d.getUint32(trun.body) & 0xffffff;
      final count = d.getUint32(trun.body + 4);
      var p = trun.body + 8;
      var dataAt = next;
      if (rf & 0x1 != 0) {
        dataAt = base + d.getInt32(p);
        p += 4;
      }
      if (rf & 0x4 != 0) p += 4;
      var length = 0;
      for (var i = 0; i < count; i++) {
        var duration = defDuration, size = defSize;
        if (rf & 0x100 != 0) {
          duration = d.getUint32(p);
          p += 4;
        }
        if (rf & 0x200 != 0) {
          size = d.getUint32(p);
          p += 4;
        }
        if (rf & 0x400 != 0) p += 4;
        if (rf & 0x800 != 0) {
          if (d.getUint32(p) != 0) return null;  // reordered samples: not audio's
          p += 4;
        }
        durations.add(duration);
        sizes.add(size);
        length += size;
      }
      if (count == 0) continue;
      if (dataAt + length > src.length) return null;
      chunks.add((dataAt, length, count));
      next = dataAt + length;
    }
  }
  if (sizes.isEmpty) return null;

  final total = durations.fold<int>(0, (n, x) => n + x);
  final mediaScale = _timescale(d, mdhd);
  final movieScale = _timescale(d, mvhd);
  final movieTotal = mediaScale == 0 ? 0 : (total * movieScale / mediaScale).round();

  // The samples' table, once.
  final stts = <int>[];
  for (var i = 0; i < durations.length;) {
    var j = i;
    while (j < durations.length && durations[j] == durations[i]) {
      j++;
    }
    stts.addAll([j - i, durations[i]]);
    i = j;
  }
  final sttsBox = _full('stts', 0, 0, [
    _u32(stts.length ~/ 2),
    for (final v in stts) _u32(v),
  ]);
  final sameSize = sizes.every((s) => s == sizes.first);
  final stszBox = _full('stsz', 0, 0, [
    _u32(sameSize ? sizes.first : 0),
    _u32(sizes.length),
    if (!sameSize) for (final s in sizes) _u32(s),
  ]);
  final stsc = <int>[];
  for (var c = 0; c < chunks.length; c++) {
    if (c == 0 || chunks[c].$3 != chunks[c - 1].$3) stsc.addAll([c + 1, chunks[c].$3, 1]);
  }
  final stscBox = _full('stsc', 0, 0, [
    _u32(stsc.length ~/ 3),
    for (final v in stsc) _u32(v),
  ]);

  final ftyp = _box('ftyp', [
    ascii.encode('M4A '), _u32(0x200),
    ascii.encode('M4A '), ascii.encode('isom'), ascii.encode('iso2'), ascii.encode('mp41'),
  ]);

  Uint8List moovWith(List<int> chunkOffsets) {
    final stco = _full('stco', 0, 0, [
      _u32(chunkOffsets.length),
      for (final o in chunkOffsets) _u32(o),
    ]);
    final newStbl = _box('stbl', [_bytes(src, stsd), sttsBox, stscBox, stszBox, stco]);
    final newMinf = _box('minf', [
      for (final b in inMinf) b.type == 'stbl' ? newStbl : _bytes(src, b),
    ]);
    final newMdia = _box('mdia', [
      for (final b in inMdia)
        switch (b.type) {
          'mdhd' => _withDuration(src, b, total, durationAt: _durationAt(d, b, 'mdhd')),
          'minf' => newMinf,
          _ => _bytes(src, b),
        },
    ]);
    final newTrak = _box('trak', [
      for (final b in inTrak)
        switch (b.type) {
          'tkhd' => _withDuration(src, b, movieTotal, durationAt: _durationAt(d, b, 'tkhd')),
          'mdia' => newMdia,
          'edts' => _edits(src, d, b, total, movieScale, mediaScale),
          _ => _bytes(src, b),
        },
    ]);
    return _box('moov', [
      for (final b in inMoov)
        if (b.type != 'mvex')
          switch (b.type) {
            'mvhd' => _withDuration(src, b, movieTotal, durationAt: _durationAt(d, b, 'mvhd')),
            'trak' => newTrak,
            _ => _bytes(src, b),
          },
    ]);
  }

  final dataLength = chunks.fold<int>(0, (n, c) => n + c.$2);
  if (ftyp.length + dataLength > 0xffffffff - (1 << 20)) return null;  // stco is 32 bits
  final sized = moovWith(List.filled(chunks.length, 0));
  final dataStart = ftyp.length + sized.length + 8;
  final offsets = <int>[];
  var pos = dataStart;
  for (final c in chunks) {
    offsets.add(pos);
    pos += c.$2;
  }
  final newMoov = moovWith(offsets);
  assert(newMoov.length == sized.length);

  final out = BytesBuilder(copy: false)
    ..add(ftyp)
    ..add(newMoov)
    ..add(_u32(8 + dataLength))
    ..add(ascii.encode('mdat'));
  for (final c in chunks) {
    out.add(Uint8List.sublistView(src, c.$1, c.$1 + c.$2));
  }
  return out.takeBytes();
}

Uint8List _bytes(Uint8List src, _Box b) => Uint8List.sublistView(src, b.start, b.end);

/// mvhd and mdhd: version, then two times, then the timescale.
int _timescale(ByteData d, _Box b) {
  final v = d.getUint8(b.body);
  return d.getUint32(b.body + (v == 1 ? 20 : 12));
}

/// Where the duration sits in mvhd, mdhd or tkhd, and how wide it is.
(int, int) _durationAt(ByteData d, _Box b, String type) {
  final v = d.getUint8(b.body);
  final base = b.body;
  return switch (type) {
    // version+flags, creation, modification, timescale, duration
    'mvhd' || 'mdhd' => v == 1 ? (base + 24 - b.start, 8) : (base + 16 - b.start, 4),
    // version+flags, creation, modification, track_ID, reserved, duration
    _ => v == 1 ? (base + 28 - b.start, 8) : (base + 20 - b.start, 4),
  };
}

Uint8List _withDuration(Uint8List src, _Box b, int duration,
    {required (int, int) durationAt}) {
  final copy = Uint8List.fromList(_bytes(src, b));
  final view = ByteData.sublistView(copy);
  final (at, width) = durationAt;
  if (width == 8) {
    view.setUint64(at, duration);
  } else {
    view.setUint32(at, duration > 0xffffffff ? 0xffffffff : duration);
  }
  return copy;
}

/// A fragmented file's edit list may say "the whole thing" with a length of zero, which
/// in a plain file means "nothing": given the length it now has.
Uint8List _edits(Uint8List src, ByteData d, _Box edts, int mediaTotal, int movieScale,
    int mediaScale) {
  final elst = _first(_boxes(d, edts.body, edts.end), 'elst');
  if (elst == null) return _bytes(src, edts);
  final v = d.getUint8(elst.body);
  final count = d.getUint32(elst.body + 4);
  if (count != 1) return _bytes(src, edts);
  final at = elst.body + 8;
  final segment = v == 1 ? d.getUint64(at) : d.getUint32(at);
  if (segment != 0) return _bytes(src, edts);
  final mediaTime = v == 1 ? d.getInt64(at + 8) : d.getInt32(at + 4);
  final copy = Uint8List.fromList(_bytes(src, edts));
  final view = ByteData.sublistView(copy);
  final where = at - edts.start;
  // Rounded up: the movie's clock is coarser than the sound's (a millisecond against a
  // 44,100th of a second), and rounded down it cut the last few milliseconds off.
  final played = mediaTotal - (mediaTime > 0 ? mediaTime : 0);
  final length =
      played <= 0 || mediaScale == 0 ? 0 : (played * movieScale / mediaScale).ceil();
  if (v == 1) {
    view.setUint64(where, length);
  } else {
    view.setUint32(where, length);
  }
  return copy;
}
