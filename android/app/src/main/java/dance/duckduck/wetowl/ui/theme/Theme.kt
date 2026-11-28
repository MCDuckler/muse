package dance.duckduck.wetowl.ui.theme

import android.os.Build
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dance.duckduck.wetowl.core.Accent

/** The accent, as a colour. */
fun accentColor(a: Accent) = Color(a.argb)

fun schemeFor(accent: Color): ColorScheme {
    // Material You in the dark: a near-black ground, and every container a tone of
    // the accent — the higher the container, the more of the accent it carries.
    val ground = lerp(Color(0xFF111316), accent, 0.03f)
    fun up(f: Float, tint: Float) = lerp(lerp(ground, Color.White, f), accent, tint)
    return darkColorScheme(
        primary = accent,
        onPrimary = Color(0xFF111215),
        primaryContainer = lerp(ground, accent, 0.32f),
        onPrimaryContainer = lerp(accent, Color.White, 0.6f),
        secondary = lerp(accent, Color(0xFFC4C7D0), 0.5f),
        onSecondary = Color(0xFF111215),
        secondaryContainer = lerp(ground, accent, 0.22f),
        onSecondaryContainer = lerp(accent, Color.White, 0.72f),
        tertiary = lerp(accent, Color(0xFF7FD8FF), 0.4f),
        tertiaryContainer = lerp(ground, lerp(accent, Color(0xFF7FD8FF), 0.4f), 0.25f),
        background = ground,
        onBackground = Color(0xFFE6E7EC),
        surface = ground,
        onSurface = Color(0xFFE6E7EC),
        surfaceVariant = up(0.06f, 0.05f),
        onSurfaceVariant = Color(0xFFA6AAB4),
        surfaceContainerLowest = lerp(ground, Color.Black, 0.4f),
        surfaceContainerLow = up(0.025f, 0.03f),
        surfaceContainer = up(0.045f, 0.045f),
        surfaceContainerHigh = up(0.07f, 0.06f),
        surfaceContainerHighest = up(0.10f, 0.07f),
        surfaceBright = up(0.14f, 0.07f),
        surfaceDim = ground,
        outline = Color(0xFF555963),
        outlineVariant = Color(0xFF30333A),
        error = Color(0xFFFF8A80),
        inverseSurface = Color(0xFFE6E7EC),
        inverseOnSurface = ground,
        inversePrimary = lerp(accent, Color.Black, 0.4f),
        scrim = Color.Black,
    )
}

private val type = Typography().let { t ->
    t.copy(
        displaySmall = t.displaySmall.copy(fontWeight = FontWeight.Black, letterSpacing = (-1).sp),
        headlineLarge = t.headlineLarge.copy(fontWeight = FontWeight.Black, letterSpacing = (-0.8).sp),
        headlineMedium = t.headlineMedium.copy(fontWeight = FontWeight.ExtraBold, letterSpacing = (-0.5).sp),
        headlineSmall = t.headlineSmall.copy(fontWeight = FontWeight.Bold, letterSpacing = (-0.3).sp),
        titleLarge = t.titleLarge.copy(fontWeight = FontWeight.Bold, letterSpacing = (-0.2).sp),
        titleMedium = t.titleMedium.copy(fontWeight = FontWeight.SemiBold),
        titleSmall = t.titleSmall.copy(fontWeight = FontWeight.SemiBold),
        labelLarge = t.labelLarge.copy(fontWeight = FontWeight.SemiBold),
        labelSmall = t.labelSmall.copy(fontWeight = FontWeight.SemiBold, letterSpacing = 0.6.sp),
    )
}

/** Section labels: small, spaced, quiet. */
val Kicker = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.4.sp)

private val shapes = Shapes(
    extraSmall = androidx.compose.foundation.shape.RoundedCornerShape(8.dp),
    small = androidx.compose.foundation.shape.RoundedCornerShape(12.dp),
    medium = androidx.compose.foundation.shape.RoundedCornerShape(18.dp),
    large = androidx.compose.foundation.shape.RoundedCornerShape(26.dp),
    extraLarge = androidx.compose.foundation.shape.RoundedCornerShape(34.dp),
)

@Composable
fun WetOwlTheme(accent: Accent, content: @Composable () -> Unit) {
    val context = LocalContext.current
    val scheme = if (accent == Accent.WALLPAPER && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        dynamicDarkColorScheme(context)
    } else schemeFor(accentColor(accent))
    MaterialTheme(colorScheme = scheme, typography = type, shapes = shapes) {
        // Text and icons on the ground are the ground's ink, without a Surface
        // around every screen to say so.
        CompositionLocalProvider(androidx.compose.material3.LocalContentColor provides scheme.onBackground,
            content = content)
    }
}
