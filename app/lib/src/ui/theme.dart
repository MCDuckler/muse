import 'package:flutter/material.dart';

/// The app's look: warm ink, amber signal, glass over content.
///
/// Colours are named after what they do rather than where they are used, and both
/// themes are defined from the same roles so nothing is only legible in one of them.
class MuseTheme {
  static const ink = Color(0xFF171310);       // the icon's ground; app background
  static const amber = Color(0xFFF07A3E);     // accent: transport, selection, links
  static const ember = Color(0xFFC8511B);     // accent on light, where amber is thin
  static const paper = Color(0xFFF6F3EF);

  static ThemeData dark() => _build(Brightness.dark);
  static ThemeData light() => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: isDark ? amber : ember,
      brightness: brightness,
    ).copyWith(
      surface: isDark ? ink : paper,
      // Layers, not shadows: surfaces separate by tone so the glass has something to
      // blur that is not flat grey.
      surfaceContainerLowest: isDark ? const Color(0xFF110E0B) : Colors.white,
      surfaceContainer: isDark ? const Color(0xFF1F1A15) : const Color(0xFFEFEAE4),
      surfaceContainerHighest: isDark ? const Color(0xFF2A241D) : const Color(0xFFE4DED6),
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
