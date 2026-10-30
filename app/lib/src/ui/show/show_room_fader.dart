// A level as a fader: a picture, a name, ON/OFF (the level kept while off), a fader
// stopping at a quarter, a third, a half, three quarters, 1, 1½, 2, 3, 4, the level in
// words and what it comes to — a share of the night, or of the scene — and, where
// there is one, the way to what it opens (a scene's page).
part of 'show_room.dart';

/// The fader's stops (off is the switch beside it).
const _faderSteps = [0.25, 1 / 3, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0];

int _stepOf(double level) {
  var best = 0;
  for (var i = 1; i < _faderSteps.length; i++) {
    if ((_faderSteps[i] - level).abs() < (_faderSteps[best] - level).abs()) best = i;
  }
  return best;
}

/// A small switch in words: ON lit in the accent, OFF faint — light enough for a
/// column of them.
class _OnOff extends StatelessWidget {
  const _OnOff({required this.on, required this.onTap, this.tip, this.onWord = 'ON', this.offWord = 'OFF', this.width = 42});
  final bool on;
  final VoidCallback onTap;
  final String? tip;
  final String onWord, offWord;
  final double width;

  @override
  Widget build(BuildContext context) {
    final face = InkWell(
      borderRadius: BorderRadius.circular(5),
      onTap: () {
        feel(Feel.pick);
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: width,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? Console.a.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: on ? Console.a : Console.line, width: on ? 1.2 : 1),
        ),
        child: Text(on ? onWord : offWord, style: Console.label(8.5, color: on ? Console.a : Console.faint)),
      ),
    );
    return tip == null ? face : Tooltip(message: tip!, waitDuration: const Duration(milliseconds: 600), child: face);
  }
}

class _LevelRow extends StatelessWidget {
  const _LevelRow({
    super.key,
    required this.label,
    required this.level,
    required this.muted,
    required this.onLevel,
    required this.onMuted,
    this.share,
    this.shareTip,
    this.thumb,
    this.swatch,
    this.picture,
    this.note,
    this.live = false,
    this.onOpen,
    this.extra,
  });

  final String label;
  final double level;
  final bool muted, live;
  final double? share;
  final String? shareTip, thumb, note;
  final Color? swatch;
  final Widget? picture, extra;
  final ValueChanged<double> onLevel;
  final ValueChanged<bool> onMuted;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final off = muted || level <= 0;
    final pic = SizedBox(
      width: 56,
      height: 32,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: Opacity(
          opacity: off ? 0.35 : 1,
          child: picture ??
              (thumb != null
                  ? Image.asset(thumb!, fit: BoxFit.cover, filterQuality: FilterQuality.medium, errorBuilder: (context, _, __) => ColoredBox(color: swatch ?? Console.ground))
                  : ColoredBox(color: swatch ?? Console.ground)),
        ),
      ),
    );
    final row = Row(children: [
      pic,
      const SizedBox(width: 8),
      SizedBox(
        width: 118,
        child: Row(children: [
          Flexible(
            child: Text(label,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: off ? Console.faint : Console.ink, fontWeight: FontWeight.w600)),
          ),
          if (live) Padding(padding: const EdgeInsets.only(left: 5), child: Icon(Icons.circle, size: 7, color: Console.b)),
        ]),
      ),
      _OnOff(
        on: !off,
        tip: off ? 'Off: never — tap and it comes again (at its level)' : 'On — tap and it never comes (its level kept for when it is back)',
        onTap: () => onMuted(!off),
      ),
      Expanded(
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            tickMarkShape: const RoundSliderTickMarkShape(tickMarkRadius: 1.2),
            activeTrackColor: off ? Console.faint : Console.a,
            thumbColor: off ? Console.quiet : Console.a,
            inactiveTrackColor: Console.line,
            activeTickMarkColor: Console.ground,
            inactiveTickMarkColor: Console.quiet,
            showValueIndicator: ShowValueIndicator.onDrag,
          ),
          child: Slider(
            value: _stepOf(level <= 0 ? 1 : level).toDouble(),
            min: 0,
            max: _faderSteps.length - 1.0,
            divisions: _faderSteps.length - 1,
            label: levelWord(_faderSteps[_stepOf(level <= 0 ? 1 : level)]),
            onChanged: (v) => onLevel(_faderSteps[v.round()]),
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
        ),
      ),
      SizedBox(
        width: 40,
        child: Text(level <= 0 ? 'off' : levelWord(level), style: Console.label(9.5, color: off ? Console.faint : Console.ink)),
      ),
      SizedBox(
        width: 52,
        child: Tooltip(
          message: shareTip ?? '',
          child: Text(share == null ? '' : shareWord(off ? 0 : share!),
              textAlign: TextAlign.right, style: TextStyle(fontSize: 11.5, color: off ? Console.faint : Console.ink, fontFeatures: const [ui.FontFeature.tabularFigures()])),
        ),
      ),
      if (extra != null) extra!,
      if (onOpen != null)
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Pad(icon: Icons.chevron_right, width: 28, height: 26, colour: Console.ink, tooltip: 'Its page: $label', onTap: onOpen),
        ),
    ]);
    final body = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: note == null
          ? row
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              row,
              Padding(
                padding: const EdgeInsets.only(left: 64, top: 1),
                child: Text(note!, style: TextStyle(fontSize: 10, color: Console.quiet), maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
            ]),
    );
    return body;
  }
}
