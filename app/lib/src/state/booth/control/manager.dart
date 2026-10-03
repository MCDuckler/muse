/// The controllers plugged into this machine, and the booth they drive.
///
/// Finds devices on every transport, matches each to a layout, connects the ones it
/// knows (or the one somebody picked a layout for), survives them being pulled out
/// and plugged back in, and keeps a monitor of what came in and what was done with
/// it — the thing to watch when a controller first meets the booth.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../booth.dart';
import 'binding.dart';
import 'decoders.dart';
import 'layout.dart';
import 'transport.dart';

/// One line of the monitor.
class MonitorLine {
  MonitorLine(this.device, this.raw, this.text) : at = DateTime.now();
  final DateTime at;
  final String device;

  /// The bytes, as hex; empty for a line that is not about a packet.
  final String raw;
  final String text;

  static String hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');
}

/// A controller that is connected and driving the booth.
class ControllerSession {
  ControllerSession({
    required this.device,
    required this.layout,
    required this.decoder,
    required this.binding,
    required this.open,
  });

  final FoundDevice device;
  final ControllerLayout layout;
  final SurfaceDecoder decoder;
  final BoothBinding binding;
  final OpenDevice open;
  StreamSubscription<Uint8List>? sub;
  int packets = 0;
  String? trouble;

  Future<void> close() async {
    await sub?.cancel();
    binding.detach();
    // Lights out on the way, where the device will still take them.
    for (final off in decoder.allOff()) {
      try {
        await open.send(off);
      } catch (_) {
        break;
      }
    }
    await open.close();
  }
}

class ControllerManager extends ChangeNotifier {
  ControllerManager({
    required this.transports,
    required this.layouts,
    required this.booth,
    this.hooks = const BindingHooks(),
    SharedPreferences? prefs,
  }) : _prefs = prefs;

  final List<ControllerTransport> transports;
  final List<ControllerLayout> layouts;
  final Booth booth;
  final BindingHooks hooks;
  SharedPreferences? _prefs;

  static const _kAuto = 'muse.booth.controllers.auto';
  static const _kLayout = 'muse.booth.controllers.layout:';

  /// Devices seen on the last scan, every transport together.
  List<FoundDevice> found = const [];
  final sessions = <String, ControllerSession>{};
  final monitor = ListQueue<MonitorLine>();
  static const monitorKeeps = 300;

  /// Whether a device with a matching layout connects by itself.
  bool autoConnect = true;

  bool _started = false;
  final _subs = <StreamSubscription<void>>[];
  Timer? _rescan;

  bool get anyConnected => sessions.isNotEmpty;

  /// The transports this platform has none of, with why.
  Iterable<ControllerTransport> get missing => transports.where((t) => !t.available);

  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      _prefs ??= await SharedPreferences.getInstance();
      autoConnect = _prefs!.getBool(_kAuto) ?? true;
    } catch (_) {
      // No preferences: defaults, and nothing remembered.
    }
    var polls = false;
    for (final t in transports) {
      if (!t.available) continue;
      _subs.add(t.changes.listen((_) => unawaited(rescan())));
      polls |= t.pollsOnly;
    }
    // A transport that cannot say when something was plugged in gets looked at now
    // and then. None of the current ones needs it: a timer that never stops is a
    // timer every widget test trips over.
    if (polls) _rescan = Timer.periodic(const Duration(seconds: 3), (_) => unawaited(rescan(quiet: true)));
    await rescan();
  }

  bool _scanning = false;

  Future<void> rescan({bool quiet = false}) async {
    if (_scanning) return;
    _scanning = true;
    try {
      final all = <FoundDevice>[];
      for (final t in transports) {
        if (!t.available) continue;
        try {
          all.addAll(await t.scan());
        } catch (e) {
          if (!quiet) note('', 'scan ${t.protocol.name}: $e');
        }
      }
      final keys = {for (final d in all) d.key};
      final before = {for (final d in found) d.key};
      found = all;
      // Gone: close what was on it.
      for (final key in sessions.keys.toList()) {
        if (!keys.contains(key)) {
          note(sessions[key]!.device.name, 'unplugged');
          await _drop(key);
        }
      }
      for (final d in all) {
        if (sessions.containsKey(d.key)) continue;
        // A remote that reached the desk is connected whatever the switch says: it
        // was let in with the booth's own token, which is the asking.
        if (!autoConnect && d.protocol != Protocol.remote) continue;
        final layout = layoutFor(d);
        if (layout != null) await connect(d, layout: layout);
      }
      if (!quiet || !setEquals(before, keys)) notifyListeners();
    } finally {
      _scanning = false;
    }
  }

  /// The layout for [d]: one somebody picked for a device of this name, else the one
  /// whose match fits. Null where nothing fits — the device shows as unknown and can
  /// still be connected by hand with any layout of its protocol.
  ControllerLayout? layoutFor(FoundDevice d) {
    if (d.protocol == Protocol.remote) return ControllerLayout.remote;
    final picked = _prefs?.getString(_kLayout + _nameKey(d));
    if (picked != null) {
      for (final l in layouts) {
        if (l.id == picked && l.protocol == d.protocol) return l;
      }
    }
    for (final l in layouts) {
      if (l.protocol == d.protocol && l.matchesDevice(vid: d.vid, pid: d.pid, name: d.name)) return l;
    }
    return null;
  }

  List<ControllerLayout> layoutsFor(FoundDevice d) => [for (final l in layouts) if (l.protocol == d.protocol) l];

  static String _nameKey(FoundDevice d) => '${d.name}|${d.usbId}';

  Future<void> pickLayout(FoundDevice d, ControllerLayout? layout) async {
    final key = _kLayout + _nameKey(d);
    try {
      if (layout == null) {
        await _prefs?.remove(key);
      } else {
        await _prefs?.setString(key, layout.id);
      }
    } catch (_) {}
    if (sessions.containsKey(d.key)) await disconnect(d.key);
    if (layout != null) await connect(d, layout: layout);
    notifyListeners();
  }

  Future<void> setAutoConnect(bool on) async {
    autoConnect = on;
    notifyListeners();
    try {
      await _prefs?.setBool(_kAuto, on);
    } catch (_) {}
    if (on) await rescan();
  }

  Future<void> connect(FoundDevice d, {ControllerLayout? layout}) async {
    if (sessions.containsKey(d.key)) return;
    final use = layout ?? layoutFor(d);
    if (use == null) {
      note(d.name, 'no layout fits; pick one');
      return;
    }
    final transport = transports.firstWhere((t) => t.protocol == d.protocol);
    OpenDevice open;
    try {
      open = await transport.open(d);
    } catch (e) {
      note(d.name, 'would not open: $e');
      notifyListeners();
      return;
    }
    final decoder = SurfaceDecoder.forLayout(use);
    late final ControllerSession session;
    final binding = BoothBinding(
      booth,
      hooks: hooks,
      onLed: (led) {
        final bytes = decoder.encode(led);
        if (bytes != null) unawaited(_send(session, bytes));
      },
      onNote: (text) => note(d.name, text),
    );
    session = ControllerSession(device: d, layout: use, decoder: decoder, binding: binding, open: open);
    sessions[d.key] = session;
    session.sub = open.packets.listen(
      (bytes) => _incoming(session, bytes),
      onError: (Object e) {
        session.trouble = '$e';
        note(d.name, 'lost: $e');
        unawaited(_drop(d.key));
      },
      onDone: () {
        if (sessions[d.key] == session) {
          note(d.name, 'closed');
          unawaited(_drop(d.key));
        }
      },
    );
    note(d.name, 'connected as ${use.name}');
    // Lights out first, then as the booth is.
    for (final off in decoder.allOff()) {
      await _send(session, off);
    }
    binding.attach();
    notifyListeners();
  }

  Future<void> _send(ControllerSession s, Uint8List bytes) async {
    try {
      await s.open.send(bytes);
    } catch (e) {
      s.trouble = 'send: $e';
    }
  }

  void _incoming(ControllerSession s, Uint8List bytes) {
    s.packets++;
    final events = s.decoder.decode(bytes);
    if (events.isEmpty) {
      // Quiet about a HID report that changed nothing we map; loud about a MIDI
      // message nobody mapped, which is what finding a button is.
      if (s.layout.protocol == Protocol.midi) {
        _add(MonitorLine(s.device.name, MonitorLine.hex(bytes), 'unmapped'));
      }
      return;
    }
    for (final e in events) {
      _add(MonitorLine(s.device.name, MonitorLine.hex(bytes), '$e'));
      unawaited(s.binding.handle(e));
    }
  }

  /// Bytes as if [d] had sent them: tests, and a virtual controller.
  void inject(String key, List<int> bytes) {
    final s = sessions[key];
    if (s != null) _incoming(s, Uint8List.fromList(bytes));
  }

  Future<void> disconnect(String key) async {
    final s = sessions[key];
    if (s == null) return;
    note(s.device.name, 'disconnected');
    await _drop(key);
    notifyListeners();
  }

  Future<void> _drop(String key) async {
    final s = sessions.remove(key);
    if (s == null) return;
    try {
      await s.close();
    } catch (_) {}
    notifyListeners();
  }

  void note(String device, String text) => _add(MonitorLine(device, '', text));

  final monitorChanged = ValueNotifier<int>(0);

  void _add(MonitorLine line) {
    monitor.addLast(line);
    while (monitor.length > monitorKeeps) {
      monitor.removeFirst();
    }
    monitorChanged.value++;
  }

  void clearMonitor() {
    monitor.clear();
    monitorChanged.value++;
  }

  @override
  Future<void> dispose() async {
    _rescan?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    for (final key in sessions.keys.toList()) {
      await _drop(key);
    }
    for (final t in transports) {
      await t.dispose();
    }
    monitorChanged.dispose();
    super.dispose();
  }
}

/// The layouts shipped with the app: every `assets/controllers/*.json`.
Future<List<ControllerLayout>> shippedLayouts() async {
  final out = <ControllerLayout>[];
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final paths = manifest.listAssets().where((p) => p.startsWith('assets/controllers/') && p.endsWith('.json'));
    for (final p in paths) {
      try {
        out.add(ControllerLayout.parse(await rootBundle.loadString(p)));
      } catch (e) {
        debugPrint('controllers: $p would not read ($e)');
      }
    }
  } catch (e) {
    debugPrint('controllers: no layouts ($e)');
  }
  out.sort((a, b) => a.name.compareTo(b.name));
  return out;
}

/// Layouts from JSON strings, for tests and for one pasted in.
List<ControllerLayout> layoutsFrom(Iterable<String> jsons) =>
    [for (final j in jsons) ControllerLayout.fromJson((jsonDecode(j) as Map).cast<String, dynamic>())];
