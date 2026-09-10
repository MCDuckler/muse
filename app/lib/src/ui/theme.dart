import 'package:flutter/material.dart';

/// The app's look: warm ink, amber signal, glass over content.
///
/// Colours are named after what they do rather than where they are used, and both
/// themes are defined from the same roles so nothing is only legible in one of them.
/// A palette: what the app is made of, in five colours.
///
/// Each one is a ground and an accent rather than a theme wholesale, so every screen
/// keeps its shape and only its colour changes — and the dark and light versions come
/// from the same roles, so nothing is legible in one and lost in the other.
class Palette {
  const Palette({
    required this.id,
    required this.name,
    required this.blurb,
    required this.accentDark,
    required this.accentLight,
    required this.groundDark,
    required this.groundLight,
    this.oled = false,
  });

  final String id;
  final String name;
  final String blurb;
  final Color accentDark;
  final Color accentLight;
  final Color groundDark;
  final Color groundLight;

  /// True black, for a screen that turns pixels off rather than dimming them. The
  /// panels stay just off black so the glass still has an edge to sit on.
  final bool oled;

  static const ember = Palette(
    id: 'ember',
    name: 'Ember',
    blurb: 'Warm ink and amber. The one it has always been.',
    accentDark: Color(0xFFF07A3E),
    accentLight: Color(0xFFC8511B),
    groundDark: Color(0xFF171310),
    groundLight: Color(0xFFF6F3EF),
  );

  static const midnight = Palette(
    id: 'midnight',
    name: 'Midnight',
    blurb: 'Deep blue with a cold signal, for listening after dark.',
    accentDark: Color(0xFF7BA7FF),
    accentLight: Color(0xFF2E5AAC),
    groundDark: Color(0xFF0E1218),
    groundLight: Color(0xFFF1F3F7),
  );

  static const oledBlack = Palette(
    id: 'oled',
    name: 'OLED',
    blurb: 'True black. On this screen the background is off, not dark.',
    accentDark: Color(0xFFE9E4DC),
    accentLight: Color(0xFF2A2A2A),
    groundDark: Color(0xFF000000),
    groundLight: Color(0xFFFFFFFF),
    oled: true,
  );

  static const forest = Palette(
    id: 'forest',
    name: 'Forest',
    blurb: 'Green and moss, quieter than the amber.',
    accentDark: Color(0xFF7BC98B),
    accentLight: Color(0xFF2E6B41),
    groundDark: Color(0xFF10150F),
    groundLight: Color(0xFFF1F4EE),
  );

  static const plum = Palette(
    id: 'plum',
    name: 'Plum',
    blurb: 'Purple ground, pink signal. The loudest of them.',
    accentDark: Color(0xFFE47ACB),
    accentLight: Color(0xFF8B2F79),
    groundDark: Color(0xFF15101A),
    groundLight: Color(0xFFF7F1F6),
  );

  static const paperWhite = Palette(
    id: 'paper',
    name: 'Paper',
    blurb: 'Ink on paper, with as little colour as the app can manage.',
    accentDark: Color(0xFFD8D2C8),
    accentLight: Color(0xFF3B372F),
    groundDark: Color(0xFF191817),
    groundLight: Color(0xFFFAF8F4),
  );

  static const all = <Palette>[ember, midnight, oledBlack, forest, plum, paperWhite];

  static Palette byId(String? id) =>
      all.firstWhere((p) => p.id == id, orElse: () => ember);
}

class MuseTheme {
  static const ink = Color(0xFF171310);       // the icon's ground; app background
  static const amber = Color(0xFFF07A3E);     // accent: transport, selection, links
  static const ember = Color(0xFFC8511B);     // accent on light, where amber is thin
  static const paper = Color(0xFFF6F3EF);

  static ThemeData dark([Palette palette = Palette.ember]) =>
      _build(Brightness.dark, palette);
  static ThemeData light([Palette palette = Palette.ember]) =>
      _build(Brightness.light, palette);

  static ThemeData _build(Brightness brightness, [Palette palette = Palette.ember]) {
    final isDark = brightness == Brightness.dark;
    final ground = isDark ? palette.groundDark : palette.groundLight;
    final scheme = ColorScheme.fromSeed(
      seedColor: isDark ? palette.accentDark : palette.accentLight,
      brightness: brightness,
    ).copyWith(
      surface: ground,
      // Layers, not shadows: surfaces separate by tone so the glass has something to
      // blur that is not flat grey. On a true-black palette they step up from black
      // rather than down from it, or the glass would have nothing to sit on.
      surfaceContainerLowest: _shift(ground, isDark ? -0.02 : 0.02),
      surfaceContainer: _shift(ground, isDark ? 0.05 : -0.03),
      surfaceContainerHighest: _shift(ground, isDark ? 0.09 : -0.06),
    );

    final base = isDark ? ThemeData.dark() : ThemeData.light();
    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: _text(base.textTheme, scheme),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: 'Manrope',
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
          color: scheme.onSurface,
        ),
      ),
      // Nothing lights up because a button happens to hold focus.
      //
      // A button that has been tapped keeps the focus afterwards, and Material paints
      // a pale disc under a focused or hovered icon — which on a phone appears for no
      // reason the person did anything about, sometimes seconds later, and looks like
      // a control blinking. The press ripple stays: that one answers a finger.
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          overlayColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.pressed)
                  ? scheme.onSurface.withValues(alpha: 0.10)
                  : Colors.transparent),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        selectedTileColor: scheme.primary.withValues(alpha: 0.10),
        selectedColor: scheme.primary,
        horizontalTitleGap: 12,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.onSurface.withValues(alpha: 0.07),
        thickness: 1,
        space: 1,
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
        side: BorderSide(color: scheme.onSurface.withValues(alpha: 0.12)),
        backgroundColor: Colors.transparent,
        selectedColor: scheme.primary.withValues(alpha: 0.18),
        showCheckmark: false,
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 4,
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.onSurface.withValues(alpha: 0.16),
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: 0.14),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      navigationBarTheme: NavigationBarThemeData(
        // Transparent: the bar is glass, and the blur behind it does the work.
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        indicatorColor: scheme.primary.withValues(alpha: 0.18),
        height: 64,
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              fontFamily: 'Manrope',
              fontSize: 11.5,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
              color: states.contains(WidgetState.selected)
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            )),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }

  /// A colour a little lighter or darker than the one given, staying in its own hue.
  static Color _shift(Color base, double by) {
    final hsl = HSLColor.fromColor(base);
    return hsl.withLightness((hsl.lightness + by).clamp(0.0, 1.0)).toColor();
  }

  static TextTheme _text(TextTheme base, ColorScheme scheme) {
    TextStyle s(TextStyle? from, double size, FontWeight w, {double spacing = 0}) =>
        (from ?? const TextStyle()).copyWith(
          fontFamily: 'Manrope',
          fontSize: size,
          fontWeight: w,
          letterSpacing: spacing,
          color: scheme.onSurface,
        );

    return base.copyWith(
      headlineSmall: s(base.headlineSmall, 23, FontWeight.w700, spacing: -0.3),
      titleLarge: s(base.titleLarge, 20, FontWeight.w700, spacing: -0.2),
      titleMedium: s(base.titleMedium, 16, FontWeight.w600),
      titleSmall: s(base.titleSmall, 14, FontWeight.w600),
      bodyLarge: s(base.bodyLarge, 15.5, FontWeight.w500),
      bodyMedium: s(base.bodyMedium, 14.5, FontWeight.w400),
      bodySmall: s(base.bodySmall, 13, FontWeight.w400),
      labelLarge: s(base.labelLarge, 14, FontWeight.w600),
      labelMedium: s(base.labelMedium, 12.5, FontWeight.w500),
      labelSmall: s(base.labelSmall, 11, FontWeight.w600, spacing: 0.6),
    );
  }
}
