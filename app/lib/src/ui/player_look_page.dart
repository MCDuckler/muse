import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'mini_player.dart';
import 'spectrum.dart';
import 'snack.dart';

/// How the player screen is laid out, on a screen of its own.
///
/// Four arrangements and two switches is more than a settings list wants in the middle
/// of it — and this is a choice people make by looking, not by reading, so each one is
/// drawn as a small picture of itself rather than described in a sentence.
class PlayerLookPage extends StatelessWidget {
  const PlayerLookPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return PlayerScaffold(
      appBar: AppBar(title: const Text('Now playing')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, bottomForPlayer),
        children: [
          Text('Arrangement', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final layout in PlayerLayout.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _LayoutChoice(
                layout: layout,
                chosen: app.playerLayout == layout,
                onPick: () => app.setPlayerLayout(layout),
              ),
            ),
          const SizedBox(height: 12),
          Text('The record', style: Theme.of(context).textTheme.titleSmall),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('How big'),
            subtitle: Slider(
              value: app.coverScale,
              min: 0.5,
              max: 1.0,
              divisions: 10,
              label: '${(app.coverScale * 100).round()}%',
              onChanged: app.setCoverScale,
            ),
          ),
          if (app.coverStyle == CoverStyle.record)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('How big the record is'),
              subtitle: Slider(
                value: app.discScale,
                min: 0.6,
                max: 1.15,
                divisions: 11,
                label: '${(app.discScale * 100).round()}%',
                onChanged: app.setDiscScale,
              ),
            ),
          for (final style in CoverStyle.values)
            RadioListTile<CoverStyle>(
              value: style,
              // ignore: deprecated_member_use
              groupValue: app.coverStyle,
              title: Text(style.label),
              subtitle: Text(style.description),
              // ignore: deprecated_member_use
              onChanged: (v) => v == null ? null : app.setCoverStyle(v),
            ),
          // Only the record has an arm over it, and whether there is one at all is
          // the first question: it is a thing standing between somebody and the
          // artwork, and some people want the artwork.
          if (app.coverStyle == CoverStyle.record) ...[
            const SizedBox(height: 12),
            Text('The arm', style: Theme.of(context).textTheme.titleSmall),
            for (final arm in ArmStyle.values)
              RadioListTile<ArmStyle>(
                value: arm,
                // ignore: deprecated_member_use
                groupValue: app.armStyle,
                title: Text(arm.label),
                subtitle: Text(arm.description),
                // ignore: deprecated_member_use
                onChanged: (v) => v == null ? null : app.setArmStyle(v),
              ),
          ],
          // Only the record moves, so only the record has a direction.
          if (app.coverStyle == CoverStyle.record) ...[
            const SizedBox(height: 12),
            Text('Which way it moves',
                style: Theme.of(context).textTheme.titleSmall),
            for (final axis in ShelfAxis.values)
              RadioListTile<ShelfAxis>(
                value: axis,
                // ignore: deprecated_member_use
                groupValue: app.shelfAxis,
                title: Text(axis.label),
                subtitle: Text(axis.description),
                // ignore: deprecated_member_use
                onChanged: (v) => v == null ? null : app.setShelfAxis(v),
              ),
          ],
          SwitchListTile(
            secondary: const Icon(Icons.grain),
            title: const Text('Printed background'),
            subtitle: const Text(
                'A halftone screen behind the record, breathing with the song'),
            value: app.halftone,
            onChanged: app.setHalftone,
          ),
          if (Spectrum.available)
            SwitchListTile(
              secondary: const Icon(Icons.graphic_eq),
              title: const Text('Spectrum under the cover'),
              subtitle: const Text(
                  'The shape of what is playing. Android only reports this through '
                  'the microphone permission — nothing is recorded'),
              value: app.spectrum,
              onChanged: (on) async {
                if (!on) return app.setSpectrum(false);
                final allowed = await Spectrum.askForPermission();
                await app.setSpectrum(allowed);
                if (!allowed && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(snack(Text(
                          'Without that permission Android will not say what is '
                          'playing, so there is nothing to draw.')));
                }
              },
            ),
        ],
      ),
    );
  }
}

/// One arrangement, drawn small: where the artwork sits, where the bar goes, and how
/// the buttons are grouped. Not a screenshot — a diagram, so it stays true when the
/// screen changes.
class _LayoutChoice extends StatelessWidget {
  const _LayoutChoice({
    required this.layout,
    required this.chosen,
    required this.onPick,
  });

  final PlayerLayout layout;
  final bool chosen;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onPick,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: chosen ? scheme.primary : scheme.outlineVariant,
            width: chosen ? 2 : 1,
          ),
          color: chosen ? scheme.primary.withValues(alpha: 0.06) : null,
        ),
        child: Row(
          children: [
            _Sketch(layout: layout),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(layout.label,
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(layout.description,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            if (chosen) Icon(Icons.check_circle, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}

class _Sketch extends StatelessWidget {
  const _Sketch({required this.layout});
  final PlayerLayout layout;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget bar({double width = 1, double height = 4, bool strong = false}) =>
        FractionallySizedBox(
          widthFactor: width,
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: strong ? scheme.primary : scheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
    Widget dots(int n, {double size = 5, bool spread = false}) => Row(
          mainAxisAlignment:
              spread ? MainAxisAlignment.spaceBetween : MainAxisAlignment.center,
          children: [
            for (var i = 0; i < n; i++)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: spread ? 0 : 2),
                child: Container(
                  width: i == n ~/ 2 ? size + 2 : size,
                  height: i == n ~/ 2 ? size + 2 : size,
                  decoration: BoxDecoration(
                    color: i == n ~/ 2 ? scheme.primary : scheme.outlineVariant,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        );

    final art = Container(
      height: layout == PlayerLayout.topBar ? 34 : 28,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(3),
      ),
    );

    return SizedBox(
      width: 56,
      height: 84,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (layout == PlayerLayout.topBar) ...[
            dots(4, size: 3),
            const SizedBox(height: 3),
          ],
          art,
          const SizedBox(height: 5),
          bar(width: 0.7, height: 3),
          const Spacer(),
          if (layout == PlayerLayout.plain) ...[
            dots(4, size: 3, spread: true),
            const SizedBox(height: 4),
            bar(strong: true),
            const SizedBox(height: 6),
            dots(3, size: 7),
          ] else ...[
            Container(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 3),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                children: [
                  bar(strong: true),
                  const SizedBox(height: 4),
                  dots(3, size: layout == PlayerLayout.roomy ? 7 : 5),
                  if (layout != PlayerLayout.topBar) ...[
                    const SizedBox(height: 3),
                    dots(4, size: 3),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
