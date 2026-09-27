// The lights in the booth: down (the console as a piece of hardware), up (the
// magazine's paper), or whichever the system has.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desk/console.dart';

enum BoothLook { dark, light, system }

extension BoothLookWords on BoothLook {
  String get label => switch (this) {
        BoothLook.dark => 'Lights down',
        BoothLook.light => 'Lights up',
        BoothLook.system => 'Lights with the system',
      };
  IconData get icon => switch (this) {
        BoothLook.dark => Icons.dark_mode_outlined,
        BoothLook.light => Icons.light_mode_outlined,
        BoothLook.system => Icons.brightness_auto_outlined,
      };
  BoothLook get next => BoothLook.values[(index + 1) % BoothLook.values.length];
}

/// The one setting, kept with the booth's other preferences. Every room of the booth
/// listens and rebuilds; [apply] puts the right tones on the console before a room
/// builds its parts, which is how a static set of colours follows a setting.
class BoothLooks extends ChangeNotifier {
  static const _key = 'muse.booth.look';
  BoothLook _look = BoothLook.dark;

  BoothLook get look => _look;

  /// What was kept, read again each time a room opens: cheap, and a test that sets
  /// the preference between rooms is honoured.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString(_key);
      final found = BoothLook.values.where((l) => l.name == name);
      if (found.isNotEmpty && found.first != _look) {
        _look = found.first;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> set(BoothLook look) async {
    if (look == _look) return;
    _look = look;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, look.name);
    } catch (_) {}
  }

  Future<void> cycle() => set(_look.next);

  /// Whether the lights are up for [context], and the console's tones set to match.
  /// Called at the top of every room's build: a static read by every part below it.
  bool apply(BuildContext context) {
    final light = switch (_look) {
      BoothLook.dark => false,
      BoothLook.light => true,
      BoothLook.system => MediaQuery.platformBrightnessOf(context) == Brightness.light,
    };
    Console.tones = light ? ConsoleTones.lit : ConsoleTones.dark;
    return light;
  }
}

final boothLook = BoothLooks();

/// The one button that cycles the lights, for the bars of the desk and the phone.
class LookButton extends StatelessWidget {
  const LookButton({super.key});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: boothLook,
        builder: (context, _) => IconButton(
          icon: Icon(boothLook.look.icon, color: Console.quiet),
          tooltip: '${boothLook.look.label} · tap for ${boothLook.look.next.label.toLowerCase()}',
          onPressed: () => boothLook.cycle(),
        ),
      );
}
