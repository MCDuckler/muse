/// A controller's layout: how to recognise it, and what each of its bytes means.
///
/// Read from JSON (assets/controllers/*.json). One file per device per protocol —
/// the Hercules RMX has one for the MIDI port its driver makes and one for the HID
/// reports it sends without a driver — so adding a controller is adding a file.
///
/// ```json
/// {
///   "id": "hercules_rmx_midi", "name": "Hercules DJ Console RMX", "protocol": "midi",
///   "match": {"usb": [{"vid": "06f8", "pid": "b101"}], "names": ["RMX"]},
///   "midi": {"channel": 0, "center": 63},
///   "inputs": [
///     {"id": "deck.a.play", "kind": "button", "cc": "0x0B"},
///     {"id": "deck.a.eq.low", "kind": "pot", "cc": "0x36", "center": 63},
///     {"id": "deck.a.jog", "kind": "jog", "cc": "0x2F", "encoding": "signed7"}
///   ],
///   "outputs": [{"id": "deck.a.play", "cc": "0x0B"}]
/// }
/// ```
///
/// HID inputs say where in which report: `{"report": 1, "byte": 2, "mask": "0x04"}`
/// for a bit, `{"report": 1, "byte": 9, "max": 255, "center": 128}` for a pot, and
/// `{"report": 1, "byte": 7, "encoding": "wrap8"}` for a jog that reports a position
/// counter. HID outputs say `{"report": 0, "length": 4, "byte": 1, "mask": "0x02"}`.
library;

import 'dart:convert';

import 'surface.dart';

enum Protocol {
  midi,
  hid,

  /// A phone, a tablet or a window of this program showing the board, over a wire
  /// of JSON lines rather than bytes. See board/link.
  remote;

  static Protocol parse(String s) =>
      values.firstWhere((p) => p.name == s, orElse: () => throw FormatException('unknown protocol "$s"'));
}

/// How a layout recognises its device.
class DeviceMatch {
  const DeviceMatch({this.usb = const [], this.names = const []});

  /// USB vendor/product pairs.
  final List<(int vid, int pid)> usb;

  /// Case-insensitive substrings of the device or port name. Any one matching will
  /// do: a MIDI port's name is the only thing a driver lets through.
  final List<String> names;

  bool matches({int? vid, int? pid, String? name}) {
    if (vid != null && pid != null && usb.any((u) => u.$1 == vid && u.$2 == pid)) return true;
    if (name != null) {
      final n = name.toLowerCase();
      if (names.any((p) => n.contains(p.toLowerCase()))) return true;
    }
    return false;
  }

  factory DeviceMatch.fromJson(Map<String, dynamic> j) => DeviceMatch(
        usb: [
          for (final u in (j['usb'] as List? ?? const []))
            (_hex((u as Map)['vid']), _hex(u['pid'])),
        ],
        names: [for (final n in (j['names'] as List? ?? const [])) n as String],
      );
}

/// One input control's place on the wire.
class InputSpec {
  const InputSpec({
    required this.id,
    required this.kind,
    this.channel,
    this.cc,
    this.note,
    this.report,
    this.byte,
    this.mask = 0xFF,
    this.max = 127,
    this.center,
    this.encoding,
    this.invert = false,
  });

  final String id;
  final ControlKind kind;

  // MIDI: a CC or a note, on a channel (null = any).
  final int? channel;
  final int? cc;
  final int? note;

  // HID: a byte of a report, under a mask.
  final int? report;
  final int? byte;
  final int mask;

  /// The top of a pot's range (127 for 7-bit MIDI, 255 for a HID byte), and the
  /// value that is the centre detent, where there is one.
  final int max;
  final int? center;

  /// How a relative control says which way it turned: `signed7` (0x01.. clockwise,
  /// 0x7F.. anticlockwise, as MIDI jogs do), `wrap8` (a position counter that wraps
  /// at 256; the movement is the difference from last time), `delta` (the value
  /// already is the signed movement, as a two's-complement byte).
  final String? encoding;
  final bool invert;

  /// A pot's position 0..1, with the centre — if there is one — landing on 0.5
  /// exactly, so a knob at its detent reads as flat whichever side of the halfway
  /// mark the hardware's number happens to sit.
  double position(int raw) {
    final v = raw.clamp(0, max);
    double t;
    final c = center;
    if (c == null || c <= 0 || c >= max) {
      t = v / max;
    } else if (v <= c) {
      t = 0.5 * v / c;
    } else {
      t = 0.5 + 0.5 * (v - c) / (max - c);
    }
    return invert ? 1 - t : t;
  }

  factory InputSpec.fromJson(Map<String, dynamic> j, {Map<String, dynamic> defaults = const {}}) {
    final kind = ControlKind.parse(j['kind'] as String);
    final max = _int(j['max']) ?? _int(defaults['max']) ?? (j.containsKey('byte') ? 255 : 127);
    return InputSpec(
      id: j['id'] as String,
      kind: kind,
      channel: _int(j['channel']) ?? _int(defaults['channel']),
      cc: _int(j['cc']),
      note: _int(j['note']),
      report: _int(j['report']) ?? _int(defaults['report']),
      byte: _int(j['byte']),
      mask: _int(j['mask']) ?? 0xFF,
      max: max,
      center: _int(j['center']) ?? (kind.positional && j['centered'] == true ? _int(defaults['center']) : null),
      encoding: j['encoding'] as String? ?? (kind.relative ? defaults['encoding'] as String? : null),
      invert: j['invert'] == true,
    );
  }
}

/// One light's place on the wire.
class OutputSpec {
  const OutputSpec({
    required this.id,
    this.channel,
    this.cc,
    this.note,
    this.on = 0x7F,
    this.off = 0x00,
    this.report,
    this.length,
    this.byte,
    this.mask = 0xFF,
  });

  final String id;
  final int? channel;
  final int? cc;
  final int? note;
  final int on, off;
  final int? report;
  final int? length;
  final int? byte;
  final int mask;

  factory OutputSpec.fromJson(Map<String, dynamic> j, {Map<String, dynamic> defaults = const {}}) => OutputSpec(
        id: j['id'] as String,
        channel: _int(j['channel']) ?? _int(defaults['channel']),
        cc: _int(j['cc']),
        note: _int(j['note']),
        on: _int(j['on']) ?? _int(defaults['on']) ?? 0x7F,
        off: _int(j['off']) ?? _int(defaults['off']) ?? 0x00,
        report: _int(j['report']) ?? _int(defaults['outputReport']),
        length: _int(j['length']) ?? _int(defaults['outputLength']),
        byte: _int(j['byte']),
        mask: _int(j['mask']) ?? 0xFF,
      );
}

class ControllerLayout {
  const ControllerLayout({
    required this.id,
    required this.name,
    required this.protocol,
    required this.match,
    required this.inputs,
    required this.outputs,
    this.notes = const {},
    this.quirks = const [],
  });

  final String id;
  final String name;
  final Protocol protocol;
  final DeviceMatch match;
  final List<InputSpec> inputs;
  final List<OutputSpec> outputs;

  /// Free text per control id, shown in the controller sheet: what the binding does
  /// with it here, where that differs from the label printed on the hardware.
  final Map<String, String> notes;

  /// Named oddities the decoder knows about (none yet; the hook is here so a layout
  /// can ask for one without a schema change).
  final List<String> quirks;

  factory ControllerLayout.fromJson(Map<String, dynamic> j) {
    final protocol = Protocol.parse(j['protocol'] as String);
    final defaults = (j[protocol.name] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final layout = ControllerLayout(
      id: j['id'] as String,
      name: j['name'] as String,
      protocol: protocol,
      match: DeviceMatch.fromJson((j['match'] as Map?)?.cast<String, dynamic>() ?? const {}),
      inputs: [
        for (final i in (j['inputs'] as List? ?? const []))
          InputSpec.fromJson((i as Map).cast<String, dynamic>(), defaults: defaults),
      ],
      outputs: [
        for (final o in (j['outputs'] as List? ?? const []))
          OutputSpec.fromJson((o as Map).cast<String, dynamic>(), defaults: defaults),
      ],
      notes: (j['notes'] as Map?)?.cast<String, String>() ?? const {},
      quirks: [for (final q in (j['quirks'] as List? ?? const [])) q as String],
    );
    layout._check();
    return layout;
  }

  static ControllerLayout parse(String json) =>
      ControllerLayout.fromJson((jsonDecode(json) as Map).cast<String, dynamic>());

  /// The one layout every remote has: it speaks in control names already, so it
  /// has no addresses to map. Its lights are the board's pads.
  static const remote = ControllerLayout(
    id: 'remote-board',
    name: 'Remote board',
    protocol: Protocol.remote,
    match: DeviceMatch(),
    inputs: [],
    outputs: [],
  );

  /// Two inputs on one address would fight; say so when the file is read, not when
  /// the knob is turned.
  void _check() {
    if (protocol == Protocol.remote) return;
    final seen = <String>{};
    for (final i in inputs) {
      final key = protocol == Protocol.midi
          ? 'ch${i.channel} ${i.cc != null ? 'cc${i.cc}' : 'note${i.note}'}'
          : 'r${i.report} b${i.byte} m${i.mask}';
      if (!seen.add(key)) throw FormatException('$id: two inputs at $key (${i.id})');
      if (protocol == Protocol.midi && i.cc == null && i.note == null) {
        throw FormatException('$id: ${i.id} has neither cc nor note');
      }
      if (protocol == Protocol.hid && i.byte == null) throw FormatException('$id: ${i.id} has no byte');
    }
  }

  bool matchesDevice({int? vid, int? pid, String? name}) => match.matches(vid: vid, pid: pid, name: name);

  OutputSpec? outputFor(String id) {
    for (final o in outputs) {
      if (o.id == id) return o;
    }
    return null;
  }
}

int _hex(Object? v) => v is int ? v : int.parse(v.toString().replaceFirst(RegExp('^0[xX]'), ''), radix: 16);

int? _int(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  final s = v.toString().trim();
  if (s.startsWith('0x') || s.startsWith('0X')) return int.parse(s.substring(2), radix: 16);
  return int.parse(s);
}
