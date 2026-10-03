/// The controllers page: what is plugged in, what it is taken for, what it is saying.
///
/// Opened from the light in the booth's bar. The monitor at the bottom is the thing
/// to watch when a console first meets the booth — every packet, how it was read, and
/// what the binding made of it — so the first minutes with new hardware are "watch
/// the log, fix the layout file", not guesswork.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../state/booth/control/layout.dart';
import '../../state/booth/control/manager.dart';
import '../../state/booth/control/transport.dart';
import 'desk/console.dart';

Future<void> openControllers(BuildContext context) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ControllersPage()),
    );

/// The light in the bar: lit while a console is connected. Pressed, the page.
class ControllerLight extends StatefulWidget {
  const ControllerLight({super.key});

  @override
  State<ControllerLight> createState() => _ControllerLightState();
}

class _ControllerLightState extends State<ControllerLight> {
  ControllerManager? _m;

  @override
  void initState() {
    super.initState();
    unawaited(context.read<AppState>().controllers().then((m) {
      if (!mounted) return;
      setState(() => _m = m);
    }));
  }

  @override
  Widget build(BuildContext context) {
    final m = _m;
    if (m == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: m,
      builder: (context, _) {
        final on = m.anyConnected;
        final names = m.sessions.values.map((s) => s.device.name).join(', ');
        return IconButton(
          icon: Icon(Icons.settings_input_svideo_outlined, color: on ? Console.a : Console.quiet),
          tooltip: on ? 'Controller: $names' : 'Controllers',
          onPressed: () => openControllers(context),
        );
      },
    );
  }
}

class ControllersPage extends StatelessWidget {
  const ControllersPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Console.ground,
      appBar: AppBar(
        backgroundColor: Console.panel,
        foregroundColor: Console.ink,
        title: Text('CONTROLLERS', style: Console.label(12, color: Console.ink)),
      ),
      body: SafeArea(
        child: FutureBuilder<ControllerManager>(
          future: context.read<AppState>().controllers(),
          builder: (context, snap) {
            final m = snap.data;
            if (m == null) {
              return Center(
                child: snap.hasError
                    ? Text('${snap.error}', style: TextStyle(color: Console.b))
                    : const CircularProgressIndicator(strokeWidth: 2),
              );
            }
            return _Body(m);
          },
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body(this.m);
  final ControllerManager m;

  @override
  Widget build(BuildContext context) {
    final quiet = TextStyle(color: Console.quiet, fontSize: 13);
    return AnimatedBuilder(
      animation: m,
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Text(
              'A DJ console plugged into this device drives the booth: the decks, the mixer, the '
              'pads. One the app knows connects by itself; any other MIDI or HID device can be '
              'given a layout here.',
              style: quiet,
            ),
            const SizedBox(height: 12),
            Row(children: [
              Switch(value: m.autoConnect, onChanged: (v) => unawaited(m.setAutoConnect(v))),
              const SizedBox(width: 8),
              Expanded(child: Text('Connect known consoles when they appear', style: quiet)),
              TextButton.icon(
                onPressed: () => unawaited(m.rescan()),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Look again'),
              ),
            ]),
            const SizedBox(height: 8),
            if (m.found.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text('Nothing plugged in that looks like a controller.', style: quiet),
              ),
            for (final d in m.found) _DeviceRow(m, d),
            for (final t in m.missing)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.info_outline, size: 16, color: Console.quiet),
                  const SizedBox(width: 8),
                  Expanded(child: Text('${t.protocol.name.toUpperCase()}: ${t.unavailableWhy}', style: quiet)),
                ]),
              ),
            const SizedBox(height: 16),
            for (final s in m.sessions.values) _CheatSheet(s.layout),
            const SizedBox(height: 16),
            Row(children: [
              Text('MONITOR', style: Console.label(11)),
              const Spacer(),
              TextButton(onPressed: m.clearMonitor, child: const Text('Clear')),
            ]),
          ]),
        ),
        SizedBox(height: 220, child: _Monitor(m)),
      ]),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow(this.m, this.d);
  final ControllerManager m;
  final FoundDevice d;

  @override
  Widget build(BuildContext context) {
    final s = m.sessions[d.key];
    final fits = m.layoutFor(d);
    final choices = m.layoutsFor(d);
    final chosen = s?.layout ?? fits;
    final status = s != null
        ? (s.trouble ?? '${s.packets} packets')
        : fits != null
            ? 'known, not connected'
            : 'not known: pick a layout';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Console.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: s != null ? Console.a : Console.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(s != null ? Icons.usb : Icons.usb_off, size: 18, color: s != null ? Console.a : Console.quiet),
          const SizedBox(width: 8),
          Expanded(
            child: Text(d.name, style: TextStyle(color: Console.ink, fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          Text('${d.protocol.name.toUpperCase()}${d.usbId.isEmpty ? '' : '  ${d.usbId}'}',
              style: TextStyle(color: Console.quiet, fontSize: 11, fontFamily: 'monospace')),
        ]),
        const SizedBox(height: 6),
        Text(status, style: TextStyle(color: s?.trouble != null ? Console.b : Console.quiet, fontSize: 12)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: DropdownButton<ControllerLayout?>(
              isExpanded: true,
              value: chosen,
              dropdownColor: Console.panel,
              style: TextStyle(color: Console.ink, fontSize: 13),
              hint: Text('Layout', style: TextStyle(color: Console.quiet)),
              items: [
                for (final l in choices) DropdownMenuItem(value: l, child: Text(l.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (l) => unawaited(m.pickLayout(d, l)),
            ),
          ),
          const SizedBox(width: 12),
          if (s != null)
            OutlinedButton(onPressed: () => unawaited(m.disconnect(d.key)), child: const Text('Disconnect'))
          else
            FilledButton(
              onPressed: chosen == null ? null : () => unawaited(m.connect(d, layout: chosen)),
              child: const Text('Connect'),
            ),
        ]),
      ]),
    );
  }
}

/// What the buttons do here, where that is not what is printed on them.
class _CheatSheet extends StatelessWidget {
  const _CheatSheet(this.layout);
  final ControllerLayout layout;

  @override
  Widget build(BuildContext context) {
    if (layout.notes.isEmpty) return const SizedBox.shrink();
    final keys = layout.notes.keys.toList()..sort();
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text('${layout.name}: what the buttons do', style: TextStyle(color: Console.ink, fontSize: 13)),
      iconColor: Console.quiet,
      collapsedIconColor: Console.quiet,
      children: [
        for (final k in keys)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 150,
                child: Text(k.replaceFirst('deck.a.', ''),
                    style: TextStyle(color: Console.quiet, fontSize: 12, fontFamily: 'monospace')),
              ),
              Expanded(child: Text(layout.notes[k]!, style: TextStyle(color: Console.ink, fontSize: 12))),
            ]),
          ),
      ],
    );
  }
}

class _Monitor extends StatelessWidget {
  const _Monitor(this.m);
  final ControllerManager m;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Console.panel,
      child: ValueListenableBuilder<int>(
        valueListenable: m.monitorChanged,
        builder: (context, _, __) {
          final lines = m.monitor.toList().reversed.toList();
          if (lines.isEmpty) {
            return Center(child: Text('Nothing yet. Press something.', style: TextStyle(color: Console.quiet, fontSize: 12)));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: lines.length,
            itemBuilder: (context, i) {
              final l = lines[i];
              final t = l.at;
              final stamp = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
                  '${t.second.toString().padLeft(2, '0')}.${(t.millisecond ~/ 10).toString().padLeft(2, '0')}';
              return Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: '$stamp  ', style: TextStyle(color: Console.faint)),
                    if (l.raw.isNotEmpty) TextSpan(text: '${l.raw.padRight(14)}  ', style: TextStyle(color: Console.quiet)),
                    TextSpan(text: l.text, style: TextStyle(color: l.text.contains('unmapped') || l.text.contains('not bound') ? Console.quiet : Console.ink)),
                  ]),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
