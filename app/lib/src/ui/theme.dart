import 'package:flutter/material.dart';

import 'mag.dart';
import 'motion.dart';

/// The app's look: warm ink, amber signal, glass over content.
///
/// Colours are named after what they do rather than where they are used, and both
/// themes are defined from the same roles so nothing is only legible in one of them.
/// An edition: the same magazine, printed a different way.
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

  /// The default. White coated stock and the masthead red — and at night, when the
  /// phone goes dark, the late edition: black gloss with the same red, brighter.
  static const red = Palette(
    id: 'red',
    name: 'Red',
    blurb: 'White stock and the masthead red. At night, the late edition: black gloss.',
    // A shade deeper than the logo's red on paper, so small red text still reads;
    // the masthead itself keeps the logo's own colour, MuseTheme.masthead.
    accentLight: Color(0xFFD42A20),
    accentDark: Color(0xFFFF4A3D),
    groundLight: Color(0xFFFBFAF6),
    groundDark: Color(0xFF0C0C0E),
  );

  /// Grey paper and black ink, the way the weekly music papers were printed. Red is
  /// left to the masthead.
  static const newsprint = Palette(
    id: 'newsprint',
    name: 'Newsprint',
    blurb: 'Grey paper and black ink. Red is kept for the masthead.',
    accentLight: Color(0xFF141210),
    accentDark: Color(0xFFEDE9E1),
    groundLight: Color(0xFFE6E3DC),
    groundDark: Color(0xFF1A1917),
  );

  /// A late-80s club flyer: fluoro pink on black.
  static const club = Palette(
    id: 'club',
    name: 'Club flyer',
    blurb: 'Fluoro pink on black, like a flyer for the Saturday night.',
    accentLight: Color(0xFFC8007A),
    accentDark: Color(0xFFFF4FB8),
    groundLight: Color(0xFFFFF7FB),
    groundDark: Color(0xFF111111),
  );

  /// The editions. The six palettes the app had before are gone; a phone that had one
  /// of them chosen gets the default, which is Red.
  static const all = <Palette>[red, newsprint, club];

  static Palette byId(String? id) =>
      all.firstWhere((p) => p.id == id, orElse: () => red);
}

/// Up a little and in, out the same way.
///
/// Eight pixels, not eighty: a page that travels half the screen to arrive is a page
/// somebody waits for. What the movement is for is saying that something new is on
/// top of what was there, and eight pixels with a fade says it in a fifth of a second.
class _RiseIn extends PageTransitionsBuilder {
  const _RiseIn();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final eased = CurvedAnimation(
      parent: animation,
      curve: Motion.enter,
      reverseCurve: Motion.exit,
    );
    return FadeTransition(
      opacity: eased,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.02), end: Offset.zero)
            .animate(eased),
        child: child,
      ),
    );
  }
}

class MuseTheme {
  /// The logo's red, exactly: the masthead, stickers, anything set big enough that
  /// its contrast is not a question.
  static const masthead = Color(0xFFE83328);
  static const ink = Color(0xFF141210);
  static const paper = Color(0xFFFBFAF6);

  /// Sticker yellow. For stickers only.
  static const highlighter = Color(0xFFFFE14D);

  static ThemeData dark([Palette palette = Palette.red]) =>
      _build(Brightness.dark, palette);
  static ThemeData light([Palette palette = Palette.red]) =>
      _build(Brightness.light, palette);

  static ThemeData _build(Brightness brightness, [Palette palette = Palette.red]) {
    final isDark = brightness == Brightness.dark;
    final ground = isDark ? palette.groundDark : palette.groundLight;
    final scheme = ColorScheme.fromSeed(
      seedColor: isDark ? palette.accentDark : palette.accentLight,
      brightness: brightness,
    ).copyWith(
      primary: isDark ? palette.accentDark : palette.accentLight,
      onPrimary: _on(isDark ? palette.accentDark : palette.accentLight),
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
      // One way of arriving, on every platform.
      //
      // Material's default is a different animation per platform — a slide from the
      // right on Android, a different slide on iOS, a fade on the desktop — which in
      // one app means a screen that opens differently depending on where it is being
      // looked at. This is the app's own: up a little and in, out the same way, in the
      // time everything else here takes.
      pageTransitionsTheme: PageTransitionsTheme(builders: {
        for (final platform in TargetPlatform.values)
          platform: const _RiseIn(),
      }),
      textTheme: _text(base.textTheme, scheme),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: false,
        // A page's name is set the way a magazine sets a section: condensed and
        // heavy, a size up from the words under it.
        titleTextStyle: Mag.headline(26, color: scheme.onSurface),
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
      // In the app's colours rather than Material's inverse surface, which in a dark
      // theme is a white slab: the brightest thing on the screen, appearing at the
      // bottom for a message about something that already worked.
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: scheme.surfaceContainerHighest,
        contentTextStyle: TextStyle(
            fontFamily: 'Manrope', fontSize: 13.5, color: scheme.onSurface),
        actionTextColor: scheme.primary,
        elevation: 6,
        insetPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
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

  /// Ink or white, whichever reads on [c].
  static Color _on(Color c) => c.computeLuminance() > 0.45 ? ink : Colors.white;

  static TextTheme _text(TextTheme base, ColorScheme scheme) {
    TextStyle s(TextStyle? from, double size, FontWeight w, {double spacing = 0}) =>
        (from ?? const TextStyle()).copyWith(
          fontFamily: 'Manrope',
          fontSize: size,
          fontWeight: w,
          letterSpacing: spacing,
          color: scheme.onSurface,
        );

    // Headlines in the magazine's face; everything that is read in a list or pressed
    // stays in Manrope, which is what it is good at.
    return base.copyWith(
      displayLarge: Mag.headline(56, color: scheme.onSurface),
      displayMedium: Mag.headline(44, color: scheme.onSurface),
      displaySmall: Mag.headline(36, color: scheme.onSurface),
      headlineLarge: Mag.headline(32, color: scheme.onSurface),
      headlineMedium: Mag.headline(28, color: scheme.onSurface),
      headlineSmall: Mag.headline(24, color: scheme.onSurface),
      titleLarge: Mag.title(21, color: scheme.onSurface),
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
