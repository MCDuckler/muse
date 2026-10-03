/// Bytes to [SurfaceEvent]s and [LedState]s back to bytes, by a [ControllerLayout].
///
/// One decoder per connected device: the HID one remembers the last report, since a
/// HID device says everything at once and the change is what matters.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'layout.dart';
import 'surface.dart';

abstract class SurfaceDecoder {
  SurfaceDecoder(this.layout);
  final ControllerLayout layout;

  /// What one packet off the wire says. Usually one event; a HID report that changed
  /// in several places gives several, an unknown packet gives none.
  List<SurfaceEvent> decode(Uint8List packet);

  /// The bytes that set the light for [led], or null where the layout has none.
  Uint8List? encode(LedState led);

  /// The bytes that put every light out.
  List<Uint8List> allOff() => [
        for (final o in layout.outputs)
          if (encode(LedState(o.id, false)) case final bytes?) bytes,
      ];

  static SurfaceDecoder forLayout(ControllerLayout layout) => switch (layout.protocol) {
        Protocol.midi => MidiDecoder(layout),
        Protocol.hid => HidDecoder(layout),
        Protocol.remote => RemoteDecoder(layout),
      };

  /// A relative control's movement from its raw byte.
  static int relative(InputSpec spec, int raw, {int? last}) {
    final v = switch (spec.encoding) {
      'signed7' => raw >= 0x40 ? raw - 0x80 : raw,
      'delta' => raw >= 0x80 ? raw - 0x100 : raw,
      'wrap8' => last == null ? 0 : _wrapped(raw - last, 256),
      'wrap7' => last == null ? 0 : _wrapped(raw - last, 128),
      _ => raw >= 0x40 ? raw - 0x80 : raw,
    };
    return spec.invert ? -v : v;
  }

  static int _wrapped(int d, int size) {
    if (d > size ~/ 2) return d - size;
    if (d < -size ~/ 2) return d + size;
    return d;
  }
}

/// MIDI: control changes and notes, one message at a time.
class MidiDecoder extends SurfaceDecoder {
  MidiDecoder(super.layout) {
    for (final i in layout.inputs) {
      _byAddress[_key(i.cc != null ? 0xB0 : 0x90, i.channel, i.cc ?? i.note!)] = i;
    }
  }

  final _byAddress = <int, InputSpec>{};
  final _lastRaw = <String, int>{};

  /// -1 for "any channel" is folded into the key as 16.
  static int _key(int kind, int? channel, int number) => (kind << 12) | ((channel ?? 16) << 7) | number;

  @override
  List<SurfaceEvent> decode(Uint8List m) {
    if (m.length < 3) return const [];
    final status = m[0] & 0xF0, channel = m[0] & 0x0F;
    final kind = switch (status) {
      0xB0 => 0xB0,
      0x90 || 0x80 => 0x90,
      _ => 0,
    };
    if (kind == 0) return const [];
    final spec = _byAddress[_key(kind, channel, m[1])] ?? _byAddress[_key(kind, null, m[1])];
    if (spec == null) return const [];
    var raw = m[2];
    if (status == 0x80) raw = 0; // a note off is a release
    final now = DateTime.now();
    switch (spec.kind) {
      case ControlKind.button:
        return [SurfaceEvent(spec.id, spec.kind, raw > 0 ? 1 : 0, raw: raw, at: now)];
      case ControlKind.pot:
      case ControlKind.fader:
        return [SurfaceEvent(spec.id, spec.kind, spec.position(raw), raw: raw, at: now)];
      case ControlKind.encoder:
      case ControlKind.jog:
        final d = SurfaceDecoder.relative(spec, raw, last: _lastRaw[spec.id]);
        _lastRaw[spec.id] = raw;
        if (d == 0) return const [];
        return [SurfaceEvent(spec.id, spec.kind, d.toDouble(), raw: raw, at: now)];
    }
  }

  @override
  Uint8List? encode(LedState led) {
    final o = layout.outputFor(led.id);
    if (o == null) return null;
    final ch = (o.channel ?? 0) & 0x0F;
    final value = led.on ? o.on : o.off;
    if (o.cc != null) return Uint8List.fromList([0xB0 | ch, o.cc!, value]);
    if (o.note != null) return Uint8List.fromList([0x90 | ch, o.note!, value]);
    return null;
  }
}

/// HID: whole reports, diffed against the last one.
class HidDecoder extends SurfaceDecoder {
  HidDecoder(super.layout) {
    for (final i in layout.inputs) {
      (_byReport[i.report ?? 0] ??= {}).putIfAbsent(i.byte!, () => []).add(i);
    }
  }

  /// report id → byte → the controls in that byte.
  final _byReport = <int, Map<int, List<InputSpec>>>{};
  final _last = <int, Uint8List>{};
  final _lastValue = <String, int>{};

  /// Output reports as last sent, so one light's change does not put the others out.
  final _out = <int, Uint8List>{};

  @override
  List<SurfaceEvent> decode(Uint8List report) {
    if (report.isEmpty) return const [];
    final id = report[0];
    final controls = _byReport[id];
    final was = _last[id];
    _last[id] = Uint8List.fromList(report);
    if (controls == null) return const [];
    final now = DateTime.now();
    final out = <SurfaceEvent>[];
    for (var i = 1; i < report.length; i++) {
      final specs = controls[i];
      if (specs == null) continue;
      if (was != null && i < was.length && was[i] == report[i]) continue;
      for (final spec in specs) {
        final raw = (report[i] & spec.mask) >> _shift(spec.mask);
        final before = _lastValue[spec.id];
        _lastValue[spec.id] = raw;
        switch (spec.kind) {
          case ControlKind.button:
            final on = raw != 0;
            // The first report is where the buttons are, not a press: one held while
            // the cable went in is not a command.
            if (before == null) continue;
            if ((before != 0) == on) continue;
            out.add(SurfaceEvent(spec.id, spec.kind, on ? 1 : 0, raw: raw, at: now));
          case ControlKind.pot:
          case ControlKind.fader:
            if (before == raw) continue;
            out.add(SurfaceEvent(spec.id, spec.kind, spec.position(raw), raw: raw, at: now));
          case ControlKind.encoder:
          case ControlKind.jog:
            // The first report is where the wheel happens to be, not a turn.
            if (before == null) continue;
            final d = SurfaceDecoder.relative(spec, raw, last: before);
            if (d != 0) out.add(SurfaceEvent(spec.id, spec.kind, d.toDouble(), raw: raw, at: now));
        }
      }
    }
    return out;
  }

  static int _shift(int mask) {
    var s = 0;
    while (mask != 0 && (mask & 1) == 0) {
      mask >>= 1;
      s++;
    }
    return s;
  }

  @override
  Uint8List? encode(LedState led) {
    final o = layout.outputFor(led.id);
    if (o == null || o.byte == null) return null;
    final id = o.report ?? 0;
    final length = o.length ?? (o.byte! + 1);
    final packet = _out[id] ??= Uint8List(length)..[0] = id;
    if (packet.length <= o.byte!) return null;
    final shifted = (led.on ? 1 : 0) << _shift(o.mask);
    packet[o.byte!] = (packet[o.byte!] & ~o.mask) | (shifted & o.mask);
    return Uint8List.fromList(packet);
  }
}

/// A remote: one JSON object per packet, already in the board's words.
///
/// `{"t":"press","bank":0,"pad":2,"down":true}` is the third pad of the first bank
/// going down — said as `board.bank.1` then `board.pad.3`, so the desk shows the
/// bank the phone is on. `bank`, `stop` and `level` are the bank row, the stop
/// button and the fader. Anything else on the wire (a ping, a hello) is not a
/// control and decodes to nothing; the link answers those itself.
class RemoteDecoder extends SurfaceDecoder {
  RemoteDecoder(super.layout);

  @override
  List<SurfaceEvent> decode(Uint8List packet) {
    final Object? parsed;
    try {
      parsed = jsonDecode(utf8.decode(packet));
    } catch (_) {
      return const [];
    }
    if (parsed is! Map) return const [];
    final m = parsed.cast<String, dynamic>();
    final at = DateTime.now();
    switch (m['t']) {
      case 'press':
        final pad = (m['pad'] as num?)?.toInt();
        if (pad == null) return const [];
        final bank = (m['bank'] as num?)?.toInt();
        final down = m['down'] != false;
        return [
          if (bank != null) SurfaceEvent(Controls.boardBank(bank + 1), ControlKind.button, 1, at: at),
          SurfaceEvent(Controls.boardPad(pad + 1), ControlKind.button, down ? 1 : 0, at: at),
        ];
      case 'bank':
        final bank = (m['bank'] as num?)?.toInt();
        return bank == null ? const [] : [SurfaceEvent(Controls.boardBank(bank + 1), ControlKind.button, 1, at: at)];
      case 'stop':
        return [SurfaceEvent(Controls.boardStop, ControlKind.button, 1, at: at)];
      case 'level':
        final v = (m['v'] as num?)?.toDouble();
        return v == null ? const [] : [SurfaceEvent(Controls.boardLevel, ControlKind.fader, v.clamp(0.0, 1.0), at: at)];
    }
    return const [];
  }

  @override
  Uint8List? encode(LedState led) =>
      Uint8List.fromList(utf8.encode(jsonEncode({'t': 'lit', 'id': led.id, 'on': led.on})));
}
